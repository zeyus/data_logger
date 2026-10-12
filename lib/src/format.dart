import 'entry.dart';

/// Turns an entry into one line of text, without the line terminator.
///
/// Runs on the writer isolate, so it must be a top-level or static function,
/// or a closure that captures only sendable state.
typedef LineFormatter = String Function(LogEntry entry);

/// How the rows of a data log are laid out.
///
/// Columns are always `timestamp, event, data, clock` followed by the logger's
/// context columns. Their positions are fixed: a row with no clock or no
/// context still writes the empty fields.
final class RowFormat {
  /// File extension, without the dot.
  final String extension;

  /// Formats one entry as a line.
  final LineFormatter formatter;

  /// Joins already-separate field values into a line fragment. Used for the
  /// header row and for the context columns.
  final String Function(List<String> fields) joinFields;

  const RowFormat({
    required this.extension,
    required this.formatter,
    required this.joinFields,
  });

  /// Tab-separated. Tabs and line breaks in the event name or a context value
  /// are written as `\t`, `\n` and `\r`; the JSON payload never contains them.
  static const RowFormat tsv = RowFormat(
    extension: 'tsv',
    formatter: formatTsv,
    joinFields: joinTsv,
  );

  /// Comma-separated per RFC 4180. Every field except the clock is quoted.
  static const RowFormat csv = RowFormat(
    extension: 'csv',
    formatter: formatCsv,
    joinFields: joinCsv,
  );

  /// The names of the four leading columns.
  static const List<String> baseColumns = [
    'timestamp',
    'event',
    'data',
    'clock',
  ];

  /// The header line for a logger with these context columns.
  String header(List<String> contextColumns) =>
      joinFields([...baseColumns, ...contextColumns]);
}

String _tsvEscape(String value) {
  if (!value.contains('\t') && !value.contains('\n') && !value.contains('\r')) {
    return value;
  }
  return value
      .replaceAll('\t', r'\t')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r');
}

String _csvQuote(String value) => '"${value.replaceAll('"', '""')}"';

/// Joins fields with tabs, escaping tabs and line breaks inside them.
String joinTsv(List<String> fields) => fields.map(_tsvEscape).join('\t');

/// Joins fields with commas, quoting each.
String joinCsv(List<String> fields) => fields.map(_csvQuote).join(',');

/// The [RowFormat.tsv] formatter.
String formatTsv(LogEntry entry) {
  if (entry is! DataRow) {
    return '${entry.timestamp}\t${_tsvEscape(entry.message)}';
  }
  final buffer = StringBuffer()
    ..write(entry.timestamp)
    ..write('\t')
    ..write(_tsvEscape(entry.message))
    ..write('\t')
    ..write(entry.data)
    ..write('\t');
  if (entry.clock != null) buffer.write(entry.clock);
  if (entry.context != null) {
    buffer
      ..write('\t')
      ..write(entry.context);
  }
  return buffer.toString();
}

/// The [RowFormat.csv] formatter.
String formatCsv(LogEntry entry) {
  if (entry is! DataRow) {
    return '${_csvQuote(entry.timestamp)},${_csvQuote(entry.message)}';
  }
  final buffer = StringBuffer()
    ..write(_csvQuote(entry.timestamp))
    ..write(',')
    ..write(_csvQuote(entry.message))
    ..write(',')
    ..write(_csvQuote(entry.data))
    ..write(',');
  if (entry.clock != null) buffer.write(entry.clock);
  if (entry.context != null) {
    buffer
      ..write(',')
      ..write(entry.context);
  }
  return buffer.toString();
}

/// The formatter used for the application log.
String formatAppLog(LogEntry entry) => entry is AppLogEntry
    ? entry.format()
    : '${entry.timestamp} ${entry.message}';
