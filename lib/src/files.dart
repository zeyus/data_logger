import 'package:logging/logging.dart';

import 'format.dart';

/// A log file on disk.
final class LogFileInfo {
  final String path;
  final String name;
  final int size;
  final DateTime modified;

  /// Whether this is a file the logger is writing to right now.
  final bool isCurrent;

  /// Whether the file is in the application-log directory rather than the
  /// data-log directory.
  final bool isAppLog;

  /// The data logger the file belongs to, or null for application logs and
  /// for data files that match no logger open in this run.
  final String? logger;

  const LogFileInfo({
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
    required this.isCurrent,
    required this.isAppLog,
    this.logger,
  });

  @override
  String toString() => 'LogFileInfo($path, $size bytes, current: $isCurrent)';
}

/// The files a rotation set aside.
final class RotatedLogs {
  /// The rotated application log, or null if there was none to rotate.
  final String? appLog;

  /// The rotated file of each data logger, by logger name.
  final Map<String, String> dataLogs;

  const RotatedLogs({required this.appLog, required this.dataLogs});

  /// Every rotated path.
  List<String> get all => [?appLog, ...dataLogs.values];
}

/// What a purge removed.
final class PurgeResult {
  final int deletedCount;
  final int failedCount;

  /// Bytes freed.
  final int totalSize;

  const PurgeResult({
    required this.deletedCount,
    required this.failedCount,
    required this.totalSize,
  });
}

/// Everything another isolate needs to log into the same files.
///
/// Get one from `DataLogger.handle`, send it to the isolate (as a spawn
/// argument, a message, or captured by an `Isolate.run` closure), and pass it
/// to `DataLogger.attach` there. It is a snapshot: loggers opened and context
/// set after it was taken are not in it.
final class LogHandle {
  /// The application-log writer's port, or null if there is no log file.
  final Object? appPort;

  /// Each open data logger's writer port, by logger name.
  final Map<String, Object> dataPorts;
  final Map<String, RowFormat> formats;
  final List<String> contextColumns;
  final List<String> contextValues;
  final Level minLevel;
  final String defaultLoggerName;

  const LogHandle({
    required this.appPort,
    required this.dataPorts,
    required this.formats,
    required this.contextColumns,
    required this.contextValues,
    required this.minLevel,
    required this.defaultLoggerName,
  });
}
