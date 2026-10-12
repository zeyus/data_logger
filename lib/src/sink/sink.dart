import 'dart:collection';

import '../entry.dart';
import '../format.dart';

/// Where a logger's lines end up.
abstract interface class LogSink {
  /// Whether [add] currently records anything.
  bool get isOpen;

  /// The file being written, or null when there is none.
  String? get path;

  /// The port other isolates can send entries to, or null when there is none.
  Object? get port;

  void add(LogEntry entry);

  /// Completes once everything added so far has been handed to the OS.
  Future<void> flush();

  /// Renames the current file to [rotatedPath] and continues in a fresh file
  /// at [path]. Throws if the file could not be rotated.
  Future<void> rotate(String rotatedPath);

  /// Writes out what is pending and stops.
  Future<void> close();

  /// Returns the buffered text and clears it. Memory sinks only.
  String takeBuffered();
}

/// A file found in a log directory.
typedef RawFile = ({String path, int size, DateTime modified});

/// Keeps lines in memory, for platforms without a file system and for tests.
final class MemorySink implements LogSink {
  final LineFormatter _formatter;
  final String? _header;
  final int _maxRows;
  final void Function(String) _onDiagnostic;
  final Queue<LogEntry> _rows = ListQueue<LogEntry>();
  bool _open = true;
  bool _warnedFull = false;

  MemorySink({
    required LineFormatter formatter,
    required int maxRows,
    required void Function(String) onDiagnostic,
    String? header,
  }) : _formatter = formatter,
       _header = header,
       _maxRows = maxRows,
       _onDiagnostic = onDiagnostic;

  @override
  bool get isOpen => _open;

  @override
  String? get path => null;

  @override
  Object? get port => null;

  @override
  void add(LogEntry entry) {
    if (!_open) return;
    if (_rows.length >= _maxRows) {
      _rows.removeFirst();
      if (!_warnedFull) {
        _warnedFull = true;
        _onDiagnostic(
          'data_logger: memory buffer reached $_maxRows rows; the oldest rows '
          'are being dropped. Call takeBuffered() more often.',
        );
      }
    }
    _rows.add(entry);
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> rotate(String rotatedPath) =>
      throw UnsupportedError('A memory-backed log has no file to rotate.');

  /// Stops recording. What is buffered can still be taken.
  @override
  Future<void> close() async => _open = false;

  @override
  String takeBuffered() {
    final buffer = StringBuffer();
    if (_header != null) buffer.writeln(_header);
    for (final row in _rows) {
      buffer.writeln(_formatter(row));
    }
    _rows.clear();
    _warnedFull = false;
    return buffer.toString();
  }
}
