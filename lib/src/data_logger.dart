import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'context.dart';
import 'entry.dart';
import 'files.dart';
import 'format.dart';
import 'sink/platform.dart' as platform;
import 'sink/sink.dart';

/// One output: the application log, or a named data log.
final class _Channel {
  final LogSink sink;
  final RowFormat? format;
  final Queue<LogEntry> buffer = ListQueue<LogEntry>();
  Timer? timer;

  /// The context columns in this channel's format; see [DataRow.context].
  String? contextText;

  _Channel(this.sink, {this.format});

  void add(LogEntry entry, int bufferSize) {
    if (!sink.isOpen) return;
    if (bufferSize <= 1) {
      sink.add(entry);
      return;
    }
    buffer.add(entry);
    if (buffer.length >= bufferSize) drain();
  }

  /// Hands everything buffered to the sink.
  void drain() {
    while (buffer.isNotEmpty) {
      sink.add(buffer.removeFirst());
    }
  }

  void stopTimer() {
    timer?.cancel();
    timer = null;
  }
}

/// Application logging and high-rate data logging, written off the calling
/// isolate.
///
/// There are two kinds of output:
///
///  * the **application log**: human-readable lines from [info], [warning]
///    and friends, and from every `package:logging` logger in the isolate;
///  * **data logs**: named TSV/CSV files of timestamped rows, written with
///    [logData]. Each row is `timestamp, event, JSON payload, clock` followed
///    by the [context] columns.
///
/// Rows are buffered in memory and handed to a writer isolate in batches, so
/// [logData] does no I/O. Call [flush] at checkpoints and [dispose] before
/// exiting.
///
/// Without a `directory`, and always on the web, logs are kept in memory
/// instead; collect them with [takeBuffered].
class DataLogger {
  DataLogger._({
    required String? directory,
    required this.sessionStamp,
    required Level minLevel,
    required this.console,
    required void Function(String) consoleWriter,
    required bool ansiColors,
    required bool listenToRootLogger,
    required this.defaultLoggerName,
    required RowContext context,
    required this.clock,
    required Object? Function(Object?) toEncodable,
    required int bufferSize,
    required Duration flushInterval,
    required int maxBufferedRows,
    required Duration timeout,
    required void Function(String) onDiagnostic,
    required bool attached,
  }) : _directory = directory,
       _minLevel = minLevel,
       _consoleWriter = consoleWriter,
       _ansiColors = ansiColors,
       _listenToRoot = listenToRootLogger,
       _context = context,
       _toEncodable = toEncodable,
       _bufferSize = bufferSize,
       _flushInterval = flushInterval,
       _maxBufferedRows = maxBufferedRows,
       _timeout = timeout,
       _onDiagnostic = onDiagnostic,
       _attached = attached {
    if (listenToRootLogger) {
      Logger.root.level = minLevel;
      _rootSubscription = Logger.root.onRecord.listen(_onRecord);
    }
  }

  /// Creates a logger that writes under [directory]: the application log in
  /// `directory/app`, data logs in `directory/data`.
  ///
  /// Nothing is written until [enableAppFile] or [open] is called.
  ///
  ///  * [directory]: where to write. Null keeps logs in memory. Ignored on
  ///    the web, which is always memory-backed. In a Flutter app, pass a path
  ///    from `path_provider`.
  ///  * [sessionStamp]: the suffix shared by this run's file names. Defaults
  ///    to the current time.
  ///  * [minLevel]: application log entries below this are dropped.
  ///  * [console], [consoleWriter], [ansiColors]: whether and how application
  ///    log entries are also printed. Flutter apps usually want
  ///    `console: kDebugMode, consoleWriter: debugPrint`.
  ///  * [listenToRootLogger]: record everything logged through
  ///    `package:logging` in this isolate. This sets `Logger.root.level` to
  ///    [minLevel], so filtered-out records are never built.
  ///  * [contextColumns]: the names of the [context] columns added to every
  ///    data row.
  ///  * [clock]: an extra, higher-quality clock stamped on every data row,
  ///    such as a monotonic clock or one shared across devices.
  ///  * [toEncodable]: converts payload values `jsonEncode` cannot handle.
  ///    Replaces [defaultToEncodable].
  ///  * [bufferSize], [flushInterval]: rows are handed to the writer when this
  ///    many are waiting or this much time has passed, whichever is first. A
  ///    [bufferSize] of 1 hands over every row immediately.
  ///  * [maxBufferedRows]: the cap on a memory-backed log; beyond it the
  ///    oldest rows are dropped.
  ///  * [timeout]: how long to wait for a writer to start, flush, rotate or
  ///    stop.
  ///  * [onDiagnostic]: receives the logger's own problems (a failed flush, a
  ///    full memory buffer). Defaults to `print`.
  factory DataLogger({
    String? directory,
    String? sessionStamp,
    Level minLevel = Level.INFO,
    bool console = true,
    void Function(String line)? consoleWriter,
    bool? ansiColors,
    bool listenToRootLogger = true,
    String defaultLoggerName = 'app',
    List<String> contextColumns = const [],
    double Function()? clock,
    Object? Function(Object? value)? toEncodable,
    int bufferSize = 20000,
    Duration flushInterval = const Duration(seconds: 2),
    int maxBufferedRows = 1000000,
    Duration timeout = const Duration(seconds: 5),
    void Function(String message)? onDiagnostic,
  }) => DataLogger._(
    directory: platform.hasFileSystem ? directory : null,
    sessionStamp: sessionStamp ?? _stamp(),
    minLevel: minLevel,
    console: console,
    consoleWriter: consoleWriter ?? print,
    ansiColors: ansiColors ?? platform.ansiSupported,
    listenToRootLogger: listenToRootLogger,
    defaultLoggerName: defaultLoggerName,
    context: RowContext(contextColumns),
    clock: clock,
    toEncodable: toEncodable ?? defaultToEncodable,
    bufferSize: bufferSize,
    flushInterval: flushInterval,
    maxBufferedRows: maxBufferedRows,
    timeout: timeout,
    onDiagnostic: onDiagnostic ?? print,
    attached: false,
  );

  /// Creates a logger in another isolate that writes to the files of the
  /// logger [handle] came from.
  ///
  /// It has the same logging API. Rows are sent to the writer as they are
  /// logged, with no buffer or timer on this side, so it works in an isolate
  /// that never returns to its event loop. Opening, rotating, listing and
  /// purging stay with the isolate that owns the files, and [dispose] here
  /// only detaches.
  ///
  /// [clock] and [toEncodable] are not carried by the handle; pass them again
  /// if this isolate needs them.
  factory DataLogger.attach(
    LogHandle handle, {
    bool console = true,
    void Function(String line)? consoleWriter,
    bool? ansiColors,
    bool listenToRootLogger = true,
    double Function()? clock,
    Object? Function(Object? value)? toEncodable,
    Duration timeout = const Duration(seconds: 5),
    void Function(String message)? onDiagnostic,
  }) {
    final logger = DataLogger._(
      directory: null,
      sessionStamp: '',
      minLevel: handle.minLevel,
      console: console,
      consoleWriter: consoleWriter ?? print,
      ansiColors: ansiColors ?? platform.ansiSupported,
      listenToRootLogger: listenToRootLogger,
      defaultLoggerName: handle.defaultLoggerName,
      context: RowContext(
        handle.contextColumns,
      ).merge(Map.fromIterables(handle.contextColumns, handle.contextValues)),
      clock: clock,
      toEncodable: toEncodable ?? defaultToEncodable,
      bufferSize: 1,
      flushInterval: Duration.zero,
      maxBufferedRows: 0,
      timeout: timeout,
      onDiagnostic: onDiagnostic ?? print,
      attached: true,
    );
    final appPort = handle.appPort;
    if (appPort != null) {
      logger._app = _Channel(platform.remoteSink(appPort, timeout));
    }
    handle.dataPorts.forEach((name, port) {
      final channel = _Channel(
        platform.remoteSink(port, timeout),
        format: handle.formats[name],
      );
      logger._data[name] = channel;
      logger._renderContext(channel);
    });
    return logger;
  }

  static DataLogger? _instance;

  /// An optional process-wide default, for reaching the logger without passing
  /// it around. Unset until you assign it.
  ///
  /// Static state is per isolate: assign it in each isolate that logs, to the
  /// owning logger in one and an [attach]ed logger in the others.
  static DataLogger get instance =>
      _instance ??
      (throw StateError(
        'DataLogger.instance has not been set in this isolate.',
      ));
  static set instance(DataLogger? logger) => _instance = logger;

  /// Whether [instance] has been set in this isolate.
  static bool get hasInstance => _instance != null;

  final String? _directory;
  final bool _attached;
  final bool _listenToRoot;
  final bool _ansiColors;
  final void Function(String) _consoleWriter;
  final void Function(String) _onDiagnostic;
  final Object? Function(Object?) _toEncodable;
  final int _bufferSize;
  final Duration _flushInterval;
  final int _maxBufferedRows;
  final Duration _timeout;

  /// The suffix shared by this run's file names.
  final String sessionStamp;

  /// The logger name used when a logging call does not give one.
  final String defaultLoggerName;

  /// Whether application log entries are also printed.
  bool console;

  /// An extra clock stamped on every data row, or null for an empty column.
  double Function()? clock;

  Level _minLevel;
  RowContext _context;
  _Channel? _app;
  final Map<String, _Channel> _data = {};
  final Set<String> _warnedUnknown = {};
  final StreamController<LogEntry> _controller =
      StreamController<LogEntry>.broadcast();
  StreamSubscription<LogRecord>? _rootSubscription;
  bool _disposed = false;

  static String _stamp() =>
      DateTime.now().toIso8601String().replaceAll(':', '-');

  bool get _inMemory => _directory == null;

  /// Whether logs are kept in memory rather than written to files.
  bool get isMemoryBacked => _inMemory && !_attached;

  /// Whether this logger was created with [DataLogger.attach].
  bool get isAttached => _attached;

  bool get isDisposed => _disposed;

  /// The directory application logs are written to, or null when
  /// memory-backed.
  String? get appLogDirectory =>
      _directory == null ? null : p.join(_directory, 'app');

  /// The directory data logs are written to, or null when memory-backed.
  String? get dataLogDirectory =>
      _directory == null ? null : p.join(_directory, 'data');

  /// The application log file being written, or null if there is none.
  String? get appLogPath => _app?.sink.path;

  /// Whether application log entries are being recorded.
  bool get isAppFileEnabled => _app?.sink.isOpen ?? false;

  /// The file [name] is being written to, or null if there is none.
  String? dataLogPath(String name) => _data[name]?.sink.path;

  /// Whether a data logger called [name] is recording.
  bool isOpen(String name) => _data[name]?.sink.isOpen ?? false;

  /// The names of the data loggers.
  Iterable<String> get dataLoggers => _data.keys;

  /// Every entry logged through this logger, as it is logged. Entries from
  /// attached loggers in other isolates do not appear here.
  Stream<LogEntry> get entries => _controller.stream;

  // --- Setup ---------------------------------------------------------------

  void _requireOwner(String action) {
    if (_attached) {
      throw StateError('Only the isolate that owns the files can $action.');
    }
    if (_disposed) throw StateError('This DataLogger has been disposed.');
  }

  Future<LogSink> _openSink(
    String? path,
    LineFormatter formatter,
    String? header,
  ) async {
    if (path == null) {
      return MemorySink(
        formatter: formatter,
        header: header,
        maxRows: _maxBufferedRows,
        onDiagnostic: _onDiagnostic,
      );
    }
    return platform.openFileSink(
      path: path,
      formatter: formatter,
      header: header,
      flushEveryLines: _bufferSize < 1 ? 1 : _bufferSize,
      onDiagnostic: _onDiagnostic,
      timeout: _timeout,
    );
  }

  void _startTimer(_Channel channel) {
    if (_bufferSize <= 1 || _flushInterval <= Duration.zero) return;
    channel.timer = Timer.periodic(_flushInterval, (_) => channel.drain());
  }

  /// Starts recording the application log, to [path] or to
  /// `app_<sessionStamp>.log` in [appLogDirectory].
  ///
  /// Throws if the file cannot be opened.
  Future<void> enableAppFile({String? path}) async {
    _requireOwner('enable the application log');
    if (_app != null) return;
    final target = _inMemory
        ? null
        : path ?? p.join(appLogDirectory!, 'app_$sessionStamp.log');
    final channel = _Channel(await _openSink(target, formatAppLog, null));
    _app = channel;
    _startTimer(channel);
  }

  /// Stops recording the application log, writing out what is pending.
  Future<void> disableAppFile() async {
    _requireOwner('disable the application log');
    final channel = _app;
    if (channel == null) return;
    _app = null;
    await _closeChannel(channel);
  }

  /// Opens a data logger called [name], writing to [path] or to
  /// `<name>_<sessionStamp>.<ext>` in [dataLogDirectory].
  ///
  /// With [header], a new file starts with a row of column names.
  ///
  /// Throws if the file cannot be opened.
  Future<void> open(
    String name, {
    RowFormat format = RowFormat.tsv,
    String? path,
    bool header = false,
  }) async {
    _requireOwner('open a data logger');
    if (_data.containsKey(name)) {
      throw StateError('A data logger called "$name" is already open.');
    }
    final target = _inMemory
        ? null
        : path ??
              p.join(
                dataLogDirectory!,
                '${name}_$sessionStamp.${format.extension}',
              );
    final sink = await _openSink(
      target,
      format.formatter,
      header ? format.header(_context.columns) : null,
    );
    final channel = _Channel(sink, format: format);
    _renderContext(channel);
    _data[name] = channel;
    _startTimer(channel);
  }

  /// Closes the data logger called [name], writing out what is pending.
  Future<void> close(String name) async {
    _requireOwner('close a data logger');
    final channel = _data.remove(name);
    if (channel != null) await _closeChannel(channel);
  }

  Future<void> _closeChannel(_Channel channel) async {
    channel.stopTimer();
    channel.drain();
    await channel.sink.close();
  }

  // --- Context -------------------------------------------------------------

  /// The values stamped onto every data row.
  RowContext get context => _context;

  set context(RowContext value) {
    if (!_sameColumns(value.columns, _context.columns)) {
      throw ArgumentError.value(
        value.columns,
        'context',
        'Columns must match the ones the logger was created with '
            '(${_context.columns.join(', ')})',
      );
    }
    _context = value;
    _data.values.forEach(_renderContext);
  }

  /// Replaces the given context columns and keeps the rest. Null clears a
  /// column.
  void updateContext(Map<String, Object?> values) =>
      context = _context.merge(values);

  static bool _sameColumns(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _renderContext(_Channel channel) {
    channel.contextText = _context.columns.isEmpty
        ? null
        : channel.format!.joinFields(_context.values);
  }

  // --- Application log -----------------------------------------------------

  /// The lowest level recorded in the application log.
  Level get minLevel => _minLevel;

  set minLevel(Level level) {
    _minLevel = level;
    // Keeps the root logger in step so records below the threshold are never
    // built in the first place.
    if (_listenToRoot) Logger.root.level = level;
  }

  static const _reset = '\x1B[0m';
  static const _levelColors = {
    'FINEST': '\x1B[35m',
    'FINER': '\x1B[35m',
    'FINE': '\x1B[34m',
    'CONFIG': '\x1B[36m',
    'INFO': '\x1B[32m',
    'WARNING': '\x1B[33m',
    'SEVERE': '\x1B[31m',
    'SHOUT': '\x1B[31m',
  };

  void _onRecord(LogRecord record) {
    if (record.level < _minLevel) return;
    _addApp(
      _appEntry(
        record.time,
        record.level,
        record.loggerName,
        record.message,
        record.error,
        record.stackTrace,
      ),
    );
  }

  static AppLogEntry _appEntry(
    DateTime time,
    Level level,
    String logger,
    String message,
    Object? error,
    StackTrace? stackTrace,
  ) {
    var text = message;
    if (error != null) text = '$text | $error';
    if (stackTrace != null) text = '$text\n$stackTrace';
    return AppLogEntry(
      timestamp: time.toIso8601String(),
      level: level.name,
      logger: logger,
      message: text,
    );
  }

  void _addApp(AppLogEntry entry) {
    if (_disposed) return;
    if (_controller.hasListener) _controller.add(entry);
    if (console) {
      final line = entry.format();
      final color = _ansiColors ? _levelColors[entry.level] : null;
      _consoleWriter(color == null ? line : '$color$line$_reset');
    }
    _app?.add(entry, _bufferSize);
  }

  /// Logs [message] to the application log.
  void log(
    Level level,
    String message, {
    String? logger,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (level < _minLevel) return;
    final name = logger ?? defaultLoggerName;
    if (_listenToRoot) {
      // Through package:logging, so its other listeners see the record too.
      Logger(name).log(level, message, error, stackTrace);
    } else {
      _addApp(
        _appEntry(DateTime.now(), level, name, message, error, stackTrace),
      );
    }
  }

  void finest(
    String message, {
    String? logger,
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    Level.FINEST,
    message,
    logger: logger,
    error: error,
    stackTrace: stackTrace,
  );

  void finer(
    String message, {
    String? logger,
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    Level.FINER,
    message,
    logger: logger,
    error: error,
    stackTrace: stackTrace,
  );

  void fine(
    String message, {
    String? logger,
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    Level.FINE,
    message,
    logger: logger,
    error: error,
    stackTrace: stackTrace,
  );

  void config(
    String message, {
    String? logger,
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    Level.CONFIG,
    message,
    logger: logger,
    error: error,
    stackTrace: stackTrace,
  );

  void info(
    String message, {
    String? logger,
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    Level.INFO,
    message,
    logger: logger,
    error: error,
    stackTrace: stackTrace,
  );

  void warning(
    String message, {
    String? logger,
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    Level.WARNING,
    message,
    logger: logger,
    error: error,
    stackTrace: stackTrace,
  );

  void severe(
    String message, {
    String? logger,
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    Level.SEVERE,
    message,
    logger: logger,
    error: error,
    stackTrace: stackTrace,
  );

  void shout(
    String message, {
    String? logger,
    Object? error,
    StackTrace? stackTrace,
  }) => log(
    Level.SHOUT,
    message,
    logger: logger,
    error: error,
    stackTrace: stackTrace,
  );

  // --- Data logs -----------------------------------------------------------

  /// The default conversion for payload values `jsonEncode` cannot handle.
  ///
  /// [DateTime] becomes ISO 8601, [Duration] microseconds, an [Enum] its name
  /// and any other [Iterable] a list. Anything else is asked for `toJson()`
  /// and, failing that, `toString()`: a row whose payload is a
  /// less-structured string is still a recorded event.
  static Object? defaultToEncodable(Object? value) {
    switch (value) {
      case DateTime v:
        return v.toIso8601String();
      case Duration v:
        return v.inMicroseconds;
      case Enum v:
        return v.name;
      case Iterable v:
        return v.toList(growable: false);
    }
    try {
      return (value as dynamic).toJson();
    } catch (_) {
      return value.toString();
    }
  }

  /// Encodes a payload in a way that cannot lose the row.
  ///
  /// On failure the row is still written, carrying the error and the keys
  /// that were present, so the event stays countable and timestamped. Data
  /// loss should be loud and partial, never silent and total.
  String _encode(String event, Object? data) {
    try {
      return jsonEncode(data, toEncodable: _toEncodable);
    } catch (e) {
      final keys = data is Map ? data.keys.map((k) => '$k').toList() : const [];
      severe('logData: payload for "$event" could not be encoded: $e');
      return jsonEncode({'_encode_error': '$e', '_keys': keys});
    }
  }

  /// Writes a row to the data logger called [name].
  ///
  /// [data] is JSON-encoded into the payload column; it is usually a map.
  /// [timestamp] defaults to now.
  ///
  /// Does no I/O. If no logger called [name] is open, the row goes to the
  /// application log instead, with a warning the first time.
  void logData(
    String name,
    String event, {
    Object? data = const <String, Object?>{},
    DateTime? timestamp,
  }) {
    final channel = _data[name];
    if (channel == null) {
      if (_warnedUnknown.add(name)) {
        warning('No data logger called "$name"; its rows go to this log.');
      }
      info('$name: $event ${_encode(event, data)}');
      return;
    }

    // Checked before encoding, which is the expensive part.
    final listening = _controller.hasListener;
    if (!channel.sink.isOpen && !listening) return;

    final row = DataRow(
      timestamp: (timestamp ?? DateTime.now()).toIso8601String(),
      message: event,
      data: _encode(event, data),
      clock: clock?.call(),
      context: channel.contextText,
    );
    channel.add(row, _bufferSize);
    if (listening) _controller.add(row);
  }

  // --- Flushing and shutdown -----------------------------------------------

  Iterable<_Channel> get _channels => [?_app, ..._data.values];

  /// Completes once everything logged so far has been handed to the OS.
  ///
  /// Call it at checkpoints, so a later crash cannot lose what was already
  /// logged. This is an OS-level flush, not an `fsync`: the data survives the
  /// process dying, but not necessarily the machine losing power.
  Future<void> flush() async {
    final channels = _channels.toList();
    for (final channel in channels) {
      channel.drain();
    }
    await Future.wait(channels.map((channel) => channel.sink.flush()));
  }

  /// Writes out everything pending and stops.
  ///
  /// On an attached logger this only detaches; the files stay open for the
  /// isolate that owns them.
  Future<void> dispose() async {
    if (_disposed) return;
    final channels = _channels.toList();
    for (final channel in channels) {
      channel.stopTimer();
      channel.drain();
    }
    if (_attached) {
      await Future.wait(channels.map((channel) => channel.sink.flush()));
    }
    _disposed = true;
    await _rootSubscription?.cancel();
    _rootSubscription = null;
    await Future.wait(channels.map((channel) => channel.sink.close()));
    await _controller.close();
    if (identical(_instance, this)) _instance = null;
  }

  // --- Memory-backed logs --------------------------------------------------

  /// Returns the text buffered for the data logger called [name] and clears
  /// it. Memory-backed loggers only.
  String takeBuffered(String name) {
    final channel = _data[name];
    if (channel == null) {
      throw ArgumentError.value(name, 'name', 'No such data logger');
    }
    channel.drain();
    return channel.sink.takeBuffered();
  }

  /// Returns the buffered application log text and clears it. Memory-backed
  /// loggers only.
  String takeBufferedAppLog() {
    final channel = _app;
    if (channel == null) return '';
    channel.drain();
    return channel.sink.takeBuffered();
  }

  // --- Other isolates ------------------------------------------------------

  /// A handle another isolate can pass to [DataLogger.attach] to log into the
  /// files open right now.
  LogHandle get handle {
    _requireOwner('hand out a handle');
    if (_inMemory) {
      throw UnsupportedError(
        'A memory-backed logger cannot be shared with other isolates.',
      );
    }
    final ports = <String, Object>{};
    final formats = <String, RowFormat>{};
    _data.forEach((name, channel) {
      final port = channel.sink.port;
      if (port == null) return;
      ports[name] = port;
      formats[name] = channel.format!;
    });
    return LogHandle(
      appPort: _app?.sink.port,
      dataPorts: ports,
      formats: formats,
      contextColumns: _context.columns,
      contextValues: _context.values,
      minLevel: _minLevel,
      defaultLoggerName: defaultLoggerName,
    );
  }

  // --- Files ---------------------------------------------------------------

  void _requireFiles(String action) {
    _requireOwner(action);
    if (_inMemory) {
      throw UnsupportedError('A memory-backed logger cannot $action.');
    }
  }

  static String _rotatedPath(String path, String stamp) => p.join(
    p.dirname(path),
    '${p.basenameWithoutExtension(path)}_$stamp${p.extension(path)}',
  );

  /// Sets the current files aside under a timestamped name and continues in
  /// fresh ones, without losing rows.
  ///
  /// The files set aside are complete and no longer written to, so they are
  /// safe to copy, upload or delete while logging carries on.
  Future<RotatedLogs> rotateAll() async {
    _requireFiles('rotate logs');
    final stamp = _stamp();

    Future<String?> rotate(_Channel channel, String label) async {
      final path = channel.sink.path;
      if (path == null || !channel.sink.isOpen) return null;
      channel.drain();
      final rotated = _rotatedPath(path, stamp);
      try {
        await channel.sink.rotate(rotated);
        return rotated;
      } catch (e) {
        _onDiagnostic('data_logger: rotating $label failed: $e');
        return null;
      }
    }

    final app = _app;
    final appLog = app == null ? null : await rotate(app, 'the app log');
    final dataLogs = <String, String>{};
    for (final MapEntry(key: name, value: channel) in _data.entries.toList()) {
      final rotated = await rotate(channel, name);
      if (rotated != null) dataLogs[name] = rotated;
    }
    return RotatedLogs(appLog: appLog, dataLogs: dataLogs);
  }

  /// Every file in [appLogDirectory] and [dataLogDirectory], from this run
  /// and earlier ones.
  ///
  /// Only those two directories are scanned. A log opened at an explicit path
  /// somewhere else is not listed, and neither are its rotations.
  Future<List<LogFileInfo>> listFiles() async {
    _requireFiles('list log files');
    final result = <LogFileInfo>[];

    final appPath = appLogPath;
    for (final file in await platform.listDirectory(appLogDirectory!)) {
      result.add(
        LogFileInfo(
          path: file.path,
          name: p.basename(file.path),
          size: file.size,
          modified: file.modified,
          isCurrent: appPath != null && p.equals(file.path, appPath),
          isAppLog: true,
        ),
      );
    }

    for (final file in await platform.listDirectory(dataLogDirectory!)) {
      final name = p.basename(file.path);
      String? logger;
      var isCurrent = false;
      for (final MapEntry(key: candidate, value: channel) in _data.entries) {
        final current = channel.sink.path;
        if (current != null && p.equals(file.path, current)) {
          logger = candidate;
          isCurrent = true;
          break;
        }
        // The longest match wins, so "app_data_..." belongs to "app_data"
        // and not to "app".
        final matches =
            name.startsWith('${candidate}_') || name.startsWith('$candidate.');
        if (matches && candidate.length > (logger?.length ?? -1)) {
          logger = candidate;
        }
      }
      result.add(
        LogFileInfo(
          path: file.path,
          name: name,
          size: file.size,
          modified: file.modified,
          isCurrent: isCurrent,
          isAppLog: false,
          logger: logger,
        ),
      );
    }
    return result;
  }

  /// The paths of every file from [listFiles] that is not being written to:
  /// rotated files and files left by earlier runs.
  Future<List<String>> rotatedFiles() async => [
    for (final file in await listFiles())
      if (!file.isCurrent) file.path,
  ];

  /// Permanently deletes the files [rotatedFiles] would return, or with
  /// [olderThan] only those last modified longer ago than that.
  ///
  /// Files being written to are never deleted.
  Future<PurgeResult> purgeRotated({Duration? olderThan}) async {
    _requireFiles('purge logs');
    final cutoff = olderThan == null
        ? null
        : DateTime.now().subtract(olderThan);
    var deleted = 0;
    var failed = 0;
    var size = 0;
    for (final file in await listFiles()) {
      if (file.isCurrent) continue;
      if (cutoff != null && !file.modified.isBefore(cutoff)) continue;
      try {
        if (await platform.deleteFile(file.path)) {
          deleted++;
          size += file.size;
        }
      } catch (e) {
        failed++;
        _onDiagnostic('data_logger: could not delete ${file.path}: $e');
      }
    }
    return PurgeResult(
      deletedCount: deleted,
      failedCount: failed,
      totalSize: size,
    );
  }
}
