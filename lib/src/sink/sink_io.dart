import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../entry.dart';
import '../format.dart';
import 'sink.dart';

const bool hasFileSystem = true;

bool get ansiSupported {
  try {
    return stdout.supportsAnsiEscapes;
  } catch (_) {
    return false;
  }
}

Future<LogSink> openFileSink({
  required String path,
  required LineFormatter formatter,
  required int flushEveryLines,
  required void Function(String) onDiagnostic,
  required Duration timeout,
  String? header,
}) => IsolateSink.open(
  path: path,
  formatter: formatter,
  header: header,
  flushEveryLines: flushEveryLines,
  onDiagnostic: onDiagnostic,
  timeout: timeout,
);

LogSink remoteSink(Object port, Duration timeout) =>
    _RemoteSink(port as SendPort, timeout);

Future<List<RawFile>> listDirectory(String directory) async {
  final dir = Directory(directory);
  if (!await dir.exists()) return const [];
  final files = <RawFile>[];
  await for (final entity in dir.list()) {
    if (entity is! File) continue;
    final stat = await entity.stat();
    files.add((path: entity.path, size: stat.size, modified: stat.modified));
  }
  return files;
}

/// Deletes [path], returning whether there was a file to delete.
Future<bool> deleteFile(String path) async {
  final file = File(path);
  if (!await file.exists()) return false;
  await file.delete();
  return true;
}

// Messages between a sink and its writer isolate. Requests carry their own
// reply port, so any isolate holding the writer's port can make them.

final class _WriterArgs {
  final SendPort owner;
  final String path;
  final LineFormatter formatter;
  final String? header;
  final int flushEveryLines;
  const _WriterArgs(
    this.owner,
    this.path,
    this.formatter,
    this.header,
    this.flushEveryLines,
  );
}

final class _Flush {
  final SendPort replyTo;
  const _Flush(this.replyTo);
}

final class _Rotate {
  final String rotatedPath;
  final SendPort replyTo;
  const _Rotate(this.rotatedPath, this.replyTo);
}

final class _Stop {
  const _Stop();
}

final class _Exited {
  const _Exited();
}

final class _OpenFailed {
  final String error;
  const _OpenFailed(this.error);
}

final class _Diagnostic {
  final String text;
  const _Diagnostic(this.text);
}

/// Sends a request to a writer and waits for its reply.
Future<Object?> _request(
  SendPort writer,
  Object Function(SendPort replyTo) build,
  Duration timeout, {
  Future<void>? writerExited,
}) async {
  final reply = ReceivePort();
  try {
    writer.send(build(reply.sendPort));
    final answer = reply.first;
    return await (writerExited == null
            ? answer
            : Future.any<Object?>([answer, writerExited.then((_) => true)]))
        .timeout(timeout);
  } finally {
    reply.close();
  }
}

/// Writes to a file on an isolate of its own, so the caller never blocks on
/// disk.
final class IsolateSink implements LogSink {
  @override
  final String path;
  final Duration _timeout;
  final void Function(String) _onDiagnostic;
  final ReceivePort _events = ReceivePort();
  final Completer<SendPort> _ready = Completer<SendPort>();
  final Completer<void> _exited = Completer<void>();
  Isolate? _isolate;
  SendPort? _port;

  IsolateSink._(this.path, this._timeout, this._onDiagnostic);

  /// Starts the writer. Throws if the file cannot be opened for writing.
  static Future<IsolateSink> open({
    required String path,
    required LineFormatter formatter,
    required int flushEveryLines,
    required void Function(String) onDiagnostic,
    required Duration timeout,
    String? header,
  }) async {
    final sink = IsolateSink._(path, timeout, onDiagnostic);
    sink._events.listen(sink._onEvent);
    try {
      sink._isolate = await Isolate.spawn(
        _writerMain,
        _WriterArgs(
          sink._events.sendPort,
          path,
          formatter,
          header,
          flushEveryLines,
        ),
        onExit: sink._events.sendPort,
        onError: sink._events.sendPort,
        debugName: 'data_logger $path',
      );
      sink._port = await sink._ready.future.timeout(timeout);
    } catch (_) {
      sink._kill();
      rethrow;
    }
    return sink;
  }

  void _onEvent(Object? event) {
    switch (event) {
      case SendPort port:
        if (!_ready.isCompleted) _ready.complete(port);
      case _Diagnostic(:final text):
        _onDiagnostic(text);
      case _OpenFailed(:final error):
        if (!_ready.isCompleted) {
          _ready.completeError(FileSystemException(error, path));
        }
      // An uncaught error in the writer, as [error, stack trace].
      case [final error, final stack]:
        _onDiagnostic(
          'data_logger: the writer for $path failed: $error\n$stack',
        );
      // Null is the isolate's onExit notification.
      case null || _Exited():
        if (!_ready.isCompleted) {
          _ready.completeError(
            StateError('The writer for $path exited before it was ready.'),
          );
        } else if (_port != null) {
          // Not asked to stop: from here on nothing is recorded, which must
          // not pass unnoticed.
          _onDiagnostic(
            'data_logger: the writer for $path stopped unexpectedly. '
            'Nothing more is being recorded to it.',
          );
        }
        _kill();
    }
  }

  @override
  bool get isOpen => _port != null;

  @override
  Object? get port => _port;

  @override
  void add(LogEntry entry) => _port?.send(entry);

  @override
  Future<void> flush() async {
    final port = _port;
    if (port == null) return;
    try {
      await _request(port, _Flush.new, _timeout, writerExited: _exited.future);
    } on TimeoutException {
      _onDiagnostic('data_logger: timed out waiting for $path to flush.');
    }
  }

  @override
  Future<void> rotate(String rotatedPath) async {
    final port = _port;
    if (port == null) throw StateError('The log at $path is closed.');
    final error = await _request(
      port,
      (replyTo) => _Rotate(rotatedPath, replyTo),
      _timeout,
      writerExited: _exited.future,
    );
    if (error is String) throw FileSystemException(error, path);
    if (error == true) throw StateError('The writer for $path has exited.');
  }

  @override
  Future<void> close() async {
    final port = _port;
    if (port == null) return;
    // Cleared first so nothing is sent behind the stop message.
    _port = null;
    port.send(const _Stop());
    try {
      await _exited.future.timeout(_timeout);
    } on TimeoutException {
      _onDiagnostic('data_logger: timed out waiting for $path to close.');
    }
    _kill();
  }

  @override
  String takeBuffered() =>
      throw UnsupportedError('$path is a file; read it from disk.');

  void _kill() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _port = null;
    _events.close();
    if (!_exited.isCompleted) _exited.complete();
  }
}

/// A writer owned by another isolate, reached through its port.
final class _RemoteSink implements LogSink {
  final SendPort _writer;
  final Duration _timeout;
  bool _open = true;

  _RemoteSink(this._writer, this._timeout);

  @override
  bool get isOpen => _open;

  @override
  String? get path => null;

  @override
  Object? get port => _writer;

  @override
  void add(LogEntry entry) {
    if (_open) _writer.send(entry);
  }

  /// Completes on a timeout as well: the owner may already have closed the
  /// writer, and this side has no way to know.
  @override
  Future<void> flush() async {
    try {
      await _request(_writer, _Flush.new, _timeout);
    } on TimeoutException {
      // Nothing to report to; see above.
    }
  }

  @override
  Future<void> rotate(String rotatedPath) =>
      throw StateError('Only the isolate that opened a log can rotate it.');

  /// Detaches. The writer keeps running for its owner.
  @override
  Future<void> close() async => _open = false;

  @override
  String takeBuffered() =>
      throw UnsupportedError('An attached log has nothing buffered.');
}

Future<void> _writerMain(_WriterArgs args) async {
  final owner = args.owner;
  final file = File(args.path);

  Future<IOSink> open() async {
    await file.parent.create(recursive: true);
    final isEmpty = !await file.exists() || await file.length() == 0;
    final sink = file.openWrite(mode: FileMode.append);
    if (isEmpty && args.header != null) sink.writeln(args.header);
    // Surfaces an unwritable path now rather than at the first real flush.
    await sink.flush();
    return sink;
  }

  late IOSink out;
  try {
    out = await open();
  } catch (e) {
    Isolate.exit(owner, _OpenFailed('$e'));
  }

  final inbox = ReceivePort();
  owner.send(inbox.sendPort);

  Future<void> flush() async {
    try {
      await out.flush();
    } catch (e) {
      owner.send(_Diagnostic('data_logger: flushing ${args.path} failed: $e'));
    }
  }

  var unflushed = 0;
  await for (final message in inbox) {
    if (message is LogEntry) {
      String line;
      try {
        line = args.formatter(message);
      } catch (e) {
        // A badly formatted row is still a recorded row.
        line = '${message.timestamp}\t${message.message}';
        owner.send(_Diagnostic('data_logger: formatter threw: $e'));
      }
      out.writeln(line);
      if (++unflushed >= args.flushEveryLines) {
        unflushed = 0;
        await flush();
      }
    } else if (message is _Flush) {
      unflushed = 0;
      await flush();
      message.replyTo.send(null);
    } else if (message is _Rotate) {
      unflushed = 0;
      try {
        await out.flush();
        await out.close();
        if (await file.exists()) await file.rename(message.rotatedPath);
        out = await open();
        message.replyTo.send(null);
      } catch (e) {
        message.replyTo.send('$e');
        try {
          out = await open();
        } catch (e) {
          owner.send(
            _Diagnostic('data_logger: ${args.path} could not be reopened: $e'),
          );
          break;
        }
      }
    } else if (message is _Stop) {
      break;
    }
  }

  inbox.close();
  try {
    await out.flush();
    await out.close();
  } catch (e) {
    owner.send(_Diagnostic('data_logger: closing ${args.path} failed: $e'));
  }
  Isolate.exit(owner, const _Exited());
}
