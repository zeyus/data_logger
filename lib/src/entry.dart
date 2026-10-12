/// One line of output.
///
/// Implement this to write your own kind of line with a custom [RowFormat]
/// formatter. Entries are sent to a writer isolate, so every field has to be
/// sendable; mark the class `@pragma('vm:deeply-immutable')` where you can,
/// which lets the VM pass it by reference instead of copying it.
abstract interface class LogEntry {
  /// Wall-clock time the entry was created, as ISO 8601.
  String get timestamp;

  /// The log message, or the event name of a data row.
  String get message;
}

/// A human-readable application log line.
@pragma('vm:deeply-immutable')
final class AppLogEntry implements LogEntry {
  @override
  final String timestamp;
  @override
  final String message;

  /// The level name, e.g. `INFO`.
  final String level;

  /// The name of the logger that produced the entry.
  final String? logger;

  const AppLogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.logger,
  });

  /// `timestamp [LEVEL   ] logger: message`
  String format() {
    final buffer = StringBuffer()
      ..write(timestamp)
      ..write(' [${level.padRight(8)}] ');
    if (logger != null) buffer.write('$logger: ');
    buffer.write(message);
    return buffer.toString();
  }
}

/// One row of a data log.
@pragma('vm:deeply-immutable')
final class DataRow implements LogEntry {
  @override
  final String timestamp;

  /// The event name (column 2).
  @override
  final String message;

  /// The payload, already JSON-encoded (column 3).
  final String data;

  /// The reading of the logger's clock when the row was created, or null when
  /// no clock is set (column 4, written empty when null).
  final double? clock;

  /// The context columns, already joined in the logger's format, or null when
  /// the logger has no context columns.
  ///
  /// Pre-rendered because this is the hot path: the context changes rarely
  /// and rows are created constantly, so a row only copies a reference.
  final String? context;

  const DataRow({
    required this.timestamp,
    required this.message,
    required this.data,
    this.clock,
    this.context,
  });
}
