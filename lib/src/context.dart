/// Values stamped onto every data row, in a fixed set of named columns.
///
/// Use it for whatever labels a row needs to be analysed without
/// reconstruction: session, condition, block, trial, participant.
///
/// Immutable. The logger renders it to text once when it is set, so it costs
/// nothing per row however often rows are written.
final class RowContext {
  /// The column names, in file order.
  final List<String> columns;

  /// The current value of each column, in the same order. Empty when unset.
  final List<String> values;

  RowContext._(this.columns, this.values);

  /// A context with these columns, all empty.
  factory RowContext(List<String> columns) {
    if (columns.toSet().length != columns.length) {
      throw ArgumentError.value(columns, 'columns', 'Duplicate column name');
    }
    return RowContext._(
      List.unmodifiable(columns),
      List.unmodifiable(List.filled(columns.length, '')),
    );
  }

  /// The value of [column].
  String operator [](String column) => values[_indexOf(column)];

  /// A copy with the given columns replaced and the rest kept.
  ///
  /// Values are converted with `toString()`; null clears the column.
  RowContext merge(Map<String, Object?> updates) {
    if (updates.isEmpty) return this;
    final next = List.of(values);
    updates.forEach((column, value) {
      next[_indexOf(column)] = value?.toString() ?? '';
    });
    return RowContext._(columns, List.unmodifiable(next));
  }

  /// A copy with every column empty.
  RowContext cleared() => RowContext(columns);

  /// The columns and their values as a map.
  Map<String, String> toMap() => Map.fromIterables(columns, values);

  int _indexOf(String column) {
    final index = columns.indexOf(column);
    if (index < 0) {
      throw ArgumentError.value(
        column,
        'column',
        'Not a context column (declared: ${columns.join(', ')})',
      );
    }
    return index;
  }
}
