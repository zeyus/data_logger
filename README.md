# data_logger

Buffered application and data logging for Dart and Flutter, written on a
background isolate.

It was built for a real-time experiment platform, where the log *is* the data:
rows are produced at frame rate, must never block the frame, and must not be
lost if the app later crashes.

- **Data logs**: named TSV or CSV files of timestamped rows with a JSON payload.
- **Application log**: human-readable lines, including everything logged
  through `package:logging`.
- **No I/O on the calling isolate**: rows are buffered and handed to a writer
  isolate in batches.
- **Any isolate can log to the same files**, through a sendable handle.
- **Context columns**: label every row (session, trial, participant) at no
  per-row cost.
- **A second clock column**, for a monotonic or cross-device clock.
- **Checkpoints and rotation**: `flush()` returns when the data is on disk;
  `rotateAll()` sets finished files aside while logging continues.
- **Web**: the same API, kept in memory for you to download or upload.

Pure Dart. No Flutter dependency.

## Quick start

```dart
import 'package:data_logger/data_logger.dart';

final log = DataLogger(
  directory: '/path/to/logs',
  contextColumns: ['session', 'trial'],
);
await log.enableAppFile();            // logs/app/app_<stamp>.log
await log.open('events');             // logs/data/events_<stamp>.tsv

log.updateContext({'session': 'S01', 'trial': 1});
log.info('Session started');
log.logData('events', 'RESPONSE', data: {'key': 'space', 'rt': 0.412});

await log.flush();    // a checkpoint: everything so far is on disk
await log.dispose();  // before exiting
```

Nothing is written until you call `enableAppFile()` or `open()`. Both throw if
the file cannot be opened, so a session cannot silently record nothing.

### In a Flutter app

Pass a directory from `path_provider`, and route console output through
`debugPrint`:

```dart
final support = await getApplicationSupportDirectory();
final log = DataLogger(
  directory: '${support.path}/logs',
  console: kDebugMode,
  consoleWriter: debugPrint,
);
DataLogger.instance = log; // optional: reach it from anywhere
```

## File format

One row per line, columns in fixed positions:

| # | Column | Notes |
|---|---|---|
| 1 | `timestamp` | Wall clock, ISO 8601 |
| 2 | `event` | The event name you passed |
| 3 | `data` | The payload, JSON-encoded |
| 4 | `clock` | Your `clock` callback's value, or empty |
| 5+ | context | One column per name in `contextColumns` |

Empty fields are still written, so a column never shifts. There is no header
row unless you ask for one with `open(name, header: true)`.

In TSV, tabs and line breaks in an event name or context value are written as
`\t`, `\n` and `\r`. CSV follows RFC 4180. For any other layout, pass your own
`RowFormat`; its formatter runs on the writer isolate, so it must be a
top-level or static function.

### Payloads never lose the row

`jsonEncode` throws on values it does not know. Here, `DateTime`, `Duration`,
enums and iterables are converted, and anything else falls back to `toJson()`
and then `toString()`. If encoding still fails, the row is written anyway with
an `_encode_error` payload naming the keys that were present, and the failure
is logged as `SEVERE`. Supply `toEncodable` to replace the conversion.

## Logging from other isolates

Static state is per isolate, so a singleton cannot do this on its own. Take a
handle from the logger that owns the files and attach to it:

```dart
Future<void> work(LogHandle handle) => Isolate.run(() async {
  final log = DataLogger.attach(handle);
  log.logData('events', 'ANALYSIS_DONE', data: {'score': 0.93});
  await log.flush();
  await log.dispose(); // detaches; the files stay open for their owner
});

await work(log.handle);
```

Things to know:

- A handle is a snapshot. Open your loggers and set the identity part of the
  context before taking it. Later changes on either side stay on that side.
- An attached logger sends each row straight to the writer, with no buffer or
  timer, so it also works in an isolate that never returns to its event loop.
- `clock` and `toEncodable` are not carried by the handle; pass them to
  `attach` again.
- Rows from different isolates are interleaved in the order they reach the
  writer, which is not time order: the owner batches, attached loggers do not.
  Each isolate's own rows keep their order. Sort by `timestamp` or `clock`.
- Only the owning isolate can open, close, rotate, list or purge.
- Build the `Isolate.run` closure in a function that takes the handle, as
  above. A closure captures its whole enclosing scope, and the logger itself
  cannot be sent.

## Buffering and durability

`logData` adds the row to an in-memory buffer. The buffer is handed to the
writer isolate when it reaches `bufferSize` rows (default 20,000) or every
`flushInterval` (default 2 s). Set `bufferSize: 1` to hand over every row at
once.

`flush()` completes only after the writer has confirmed the data left the
process. That survives the app crashing. It is not an `fsync`, so it does not
guarantee survival of a power cut.

The periodic timers and the writer isolates keep a command-line program alive.
Call `dispose()` when you are done.

## Rotation and clean-up

```dart
final rotated = await log.rotateAll(); // finished files, safe to copy
await upload(rotated.all);
await log.purgeRotated();              // or purgeRotated(olderThan: ...)
```

`listFiles()`, `rotatedFiles()` and `purgeRotated()` look only at the logger's
own `app` and `data` directories. Files left there by earlier runs count as
rotated. Do not point `directory` at a folder that holds anything else you
care about.

## Web

There are no files or isolates on the web, so every log is memory-backed
there, whatever `directory` is. The same happens anywhere if `directory` is
null, which is handy in tests.

```dart
await log.open('events', header: true);
log.logData('events', 'CLICK', data: {'x': 10});
final tsv = log.takeBuffered('events'); // returns the text and clears it
```

Rows beyond `maxBufferedRows` (default 1,000,000) push out the oldest ones,
with one diagnostic. Rotation, file listing, purging and handles throw
`UnsupportedError` when memory-backed.

## `package:logging`

By default the logger listens to `Logger.root`, so libraries that log through
`package:logging` end up in your application log. To avoid building records
that would be dropped, this sets `Logger.root.level` to `minLevel`. Pass
`listenToRootLogger: false` to leave the root logger alone.
