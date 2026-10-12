import '../format.dart';
import 'sink.dart';

/// No files and no isolates here: every log is memory-backed.
const bool hasFileSystem = false;

bool get ansiSupported => false;

Never _unsupported() =>
    throw UnsupportedError('data_logger has no file system on this platform.');

Future<LogSink> openFileSink({
  required String path,
  required LineFormatter formatter,
  required int flushEveryLines,
  required void Function(String) onDiagnostic,
  required Duration timeout,
  String? header,
}) => _unsupported();

LogSink remoteSink(Object port, Duration timeout) => _unsupported();

Future<List<RawFile>> listDirectory(String directory) => _unsupported();

Future<bool> deleteFile(String path) => _unsupported();
