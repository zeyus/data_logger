@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:data_logger/data_logger.dart';
import 'package:logging/logging.dart' show Logger;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A closure passed to [Isolate.run] captures its whole enclosing scope, so
/// it is built here, where the scope holds only sendable values.
Future<void> runWorker(LogHandle handle, int worker, int rows) =>
    Isolate.run(() async {
      final log = DataLogger.attach(handle, console: false);
      for (var i = 0; i < rows; i++) {
        log.logData('data', 'ROW', data: {'worker': worker, 'i': i});
      }
      log.info('worker $worker done');
      await log.flush();
      await log.dispose();
    });

String upperCaseFormatter(LogEntry entry) =>
    '${entry.message.toUpperCase()}|${entry is DataRow ? entry.data : ''}';

enum Side { left, right }

/// Throws on one row, to stand in for a formatter bug.
String fragileFormatter(LogEntry entry) =>
    entry.message == 'THROW' ? throw StateError('bad row') : formatTsv(entry);

/// Kills the writer on one row, to stand in for the isolate dying.
String fatalFormatter(LogEntry entry) =>
    entry.message == 'DIE' ? Isolate.exit() : formatTsv(entry);

/// Blocks the writer on one row, to stand in for a stalled disk.
String slowFormatter(LogEntry entry) {
  if (entry.message == 'SLOW') sleep(const Duration(milliseconds: 600));
  return formatTsv(entry);
}

RowFormat formatWith(LineFormatter formatter) =>
    RowFormat(extension: 'tsv', formatter: formatter, joinFields: joinTsv);

final class Unencodable {
  @override
  String toString() => 'unencodable!';
}

final class Hostile {
  Object? toJson() => throw StateError('no json');
  @override
  String toString() => throw StateError('no string');
}

void main() {
  late Directory temp;
  late DataLogger log;
  final diagnostics = <String>[];

  DataLogger create({
    bool memory = false,
    List<String> contextColumns = const [],
    double Function()? clock,
    Object? Function(Object?)? toEncodable,
    int bufferSize = 20000,
    Duration flushInterval = const Duration(seconds: 2),
    int maxBufferedRows = 1000000,
    Duration timeout = const Duration(seconds: 5),
    Level minLevel = Level.INFO,
    bool listenToRootLogger = true,
  }) => log = DataLogger(
    directory: memory ? null : temp.path,
    console: false,
    contextColumns: contextColumns,
    clock: clock,
    toEncodable: toEncodable,
    bufferSize: bufferSize,
    flushInterval: flushInterval,
    maxBufferedRows: maxBufferedRows,
    timeout: timeout,
    minLevel: minLevel,
    listenToRootLogger: listenToRootLogger,
    onDiagnostic: diagnostics.add,
  );

  List<String> lines(String path) =>
      const LineSplitter().convert(File(path).readAsStringSync());

  setUp(() async {
    diagnostics.clear();
    temp = await Directory.systemTemp.createTemp('data_logger_test_');
  });

  tearDown(() async {
    await log.dispose();
    await temp.delete(recursive: true);
  });

  group('application log', () {
    test('is off until enabled, and can be cycled', () async {
      create();
      expect(log.isAppFileEnabled, isFalse);
      for (var i = 0; i < 3; i++) {
        await log.enableAppFile();
        expect(log.isAppFileEnabled, isTrue);
        log.info('cycle $i');
        await log.disableAppFile();
        expect(log.isAppFileEnabled, isFalse);
      }
      final file = p.join(log.appLogDirectory!, 'app_${log.sessionStamp}.log');
      expect(lines(file), hasLength(3));
    });

    test('writes level, logger name and message', () async {
      create();
      await log.enableAppFile();
      log.info('first');
      log.warning('second', logger: 'net');
      await log.flush();

      final written = lines(log.appLogPath!);
      expect(written, hasLength(2));
      expect(written[0], matches(r'^\S+ \[INFO    \] app: first$'));
      expect(written[1], endsWith('[WARNING ] net: second'));
    });

    test('drops entries below the minimum level', () async {
      create(minLevel: Level.WARNING);
      await log.enableAppFile();
      log.info('quiet');
      log.severe('loud');
      log.minLevel = Level.FINE;
      log.fine('now audible');
      await log.flush();
      expect(lines(log.appLogPath!).map((l) => l.split(': ').last), [
        'loud',
        'now audible',
      ]);
    });

    test('keeps the error and stack trace', () async {
      create();
      await log.enableAppFile();
      log.severe('failed', error: 'boom', stackTrace: StackTrace.current);
      await log.flush();
      final text = File(log.appLogPath!).readAsStringSync();
      expect(text, contains('failed | boom'));
      expect(text, contains('data_logger_test.dart'));
    });

    test('records package:logging loggers', () async {
      create();
      await log.enableAppFile();
      Logger('third.party').info('from elsewhere');
      await log.flush();
      expect(
        lines(log.appLogPath!).single,
        endsWith('third.party: from elsewhere'),
      );
    });

    test('works without the root logger', () async {
      create(listenToRootLogger: false);
      await log.enableAppFile();
      Logger('third.party').severe('not ours');
      log.info('ours');
      await log.flush();
      expect(lines(log.appLogPath!).single, endsWith('app: ours'));
    });

    test('streams entries', () async {
      create();
      await log.open('data');
      final seen = <LogEntry>[];
      final subscription = log.entries.listen(seen.add);
      log.info('hello');
      log.logData('data', 'EVENT');
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      expect(seen[0], isA<AppLogEntry>());
      expect(seen[1], isA<DataRow>());
    });
  });

  group('data log', () {
    test('writes timestamp, event, JSON payload and an empty clock', () async {
      create();
      await log.open('data');
      final at = DateTime(2026, 1, 2, 3, 4, 5);
      log.logData(
        'data',
        'PRESS',
        data: {'x': 1, 'tab': 'a\tb'},
        timestamp: at,
      );
      log.logData('data', 'EMPTY');
      await log.flush();

      final rows = lines(log.dataLogPath('data')!).map((l) => l.split('\t'));
      expect(rows.first, [
        at.toIso8601String(),
        'PRESS',
        r'{"x":1,"tab":"a\tb"}',
        '',
      ]);
      // An empty payload still holds its column, so the clock cannot slide
      // into it.
      expect(rows.last.sublist(1), ['EMPTY', '{}', '']);
      expect(log.dataLogPath('data'), endsWith('data_${log.sessionStamp}.tsv'));
    });

    test('stamps the clock into the fourth column', () async {
      var now = 100.5;
      create(clock: () => now += 1);
      await log.open('data');
      log.logData('data', 'A');
      log.logData('data', 'B');
      await log.flush();
      final clocks = lines(
        log.dataLogPath('data')!,
      ).map((l) => l.split('\t')[3]);
      expect(clocks, ['101.5', '102.5']);
    });

    test('escapes tabs and line breaks in the event name', () async {
      create();
      await log.open('data');
      log.logData('data', 'A\tB\nC');
      await log.flush();
      final row = lines(log.dataLogPath('data')!).single.split('\t');
      expect(row, hasLength(4));
      expect(row[1], r'A\tB\nC');
    });

    test('writes RFC 4180 CSV', () async {
      create(contextColumns: ['who'], clock: () => 2.5);
      await log.open('data', format: RowFormat.csv, header: true);
      log.updateContext({'who': 'a "b"'});
      log.logData('data', 'SAY', data: {'q': 'he said "hi", twice'});
      await log.flush();

      final written = lines(log.dataLogPath('data')!);
      expect(log.dataLogPath('data'), endsWith('.csv'));
      expect(written[0], '"timestamp","event","data","clock","who"');
      expect(
        written[1],
        endsWith(r',"SAY","{""q"":""he said \""hi\"", twice""}",2.5,"a ""b"""'),
      );
    });

    test('writes a header once per file', () async {
      create(contextColumns: ['session']);
      final path = p.join(temp.path, 'fixed.tsv');
      await log.open('data', path: path, header: true);
      log.logData('data', 'A');
      await log.close('data');
      await log.open('data', path: path, header: true);
      log.logData('data', 'B');
      await log.flush();

      final written = lines(path);
      expect(written, hasLength(3));
      expect(written.first, 'timestamp\tevent\tdata\tclock\tsession');
    });

    test('keeps several loggers apart', () async {
      create();
      await log.open('a');
      await log.open('b', format: RowFormat.csv);
      for (var i = 0; i < 50; i++) {
        log.logData('a', 'A$i');
        log.logData('b', 'B$i');
      }
      await log.flush();
      expect(lines(log.dataLogPath('a')!), hasLength(50));
      expect(lines(log.dataLogPath('b')!), hasLength(50));
      expect(log.dataLoggers, ['a', 'b']);
      expect(() => log.open('a'), throwsStateError);
    });

    test('preserves order across buffer hand-overs', () async {
      create(bufferSize: 512);
      await log.open('data');
      const count = 20000;
      for (var i = 0; i < count; i++) {
        log.logData('data', 'E', data: {'i': i});
      }
      await log.flush();
      final written = lines(log.dataLogPath('data')!);
      expect(written, hasLength(count));
      for (var i = 0; i < count; i++) {
        expect(written[i].split('\t')[2], '{"i":$i}');
      }
    });

    test('flush puts every row on disk before it returns', () async {
      // Nothing else would move these rows: the buffer never fills and the
      // timer never fires.
      create(bufferSize: 1 << 30, flushInterval: const Duration(hours: 1));
      await log.open('data');
      for (var round = 1; round <= 5; round++) {
        for (var i = 0; i < 2000; i++) {
          log.logData('data', 'E');
        }
        await log.flush();
        expect(lines(log.dataLogPath('data')!), hasLength(round * 2000));
      }
    });

    test('the timer hands rows over without a flush', () async {
      create(flushInterval: const Duration(milliseconds: 20));
      await log.open('data');
      log.logData('data', 'E');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await log.close('data');
      expect(log.isOpen('data'), isFalse);
      final files = Directory(log.dataLogDirectory!).listSync();
      expect(lines(files.single.path), hasLength(1));
    });

    test('dispose writes out what is pending', () async {
      create();
      await log.enableAppFile();
      await log.open('data');
      final appPath = log.appLogPath!;
      final dataPath = log.dataLogPath('data')!;
      log.info('last words');
      log.logData('data', 'LAST');
      await log.dispose();
      expect(log.isDisposed, isTrue);
      expect(lines(appPath), hasLength(1));
      expect(lines(dataPath), hasLength(1));
    });

    test('a row for an unknown logger goes to the app log', () async {
      create();
      await log.enableAppFile();
      log.logData('nope', 'LOST', data: {'k': 1});
      log.logData('nope', 'LOST', data: {'k': 2});
      await log.flush();
      final written = lines(log.appLogPath!);
      expect(written.where((l) => l.contains('WARNING')), hasLength(1));
      expect(written.last, endsWith('nope: LOST {"k":2}'));
    });

    test('converts values jsonEncode cannot handle', () async {
      create();
      await log.open('data');
      log.logData(
        'data',
        'E',
        data: {
          'at': DateTime.utc(2026),
          'took': const Duration(milliseconds: 2),
          'side': Side.left,
          'set': {1, 2},
          'other': Unencodable(),
        },
      );
      await log.flush();
      final payload =
          jsonDecode(lines(log.dataLogPath('data')!).single.split('\t')[2])
              as Map;
      expect(payload['at'], '2026-01-01T00:00:00.000Z');
      expect(payload['took'], 2000);
      expect(payload['side'], 'left');
      expect(payload['set'], [1, 2]);
      expect(payload['other'], 'unencodable!');
    });

    test('a payload that cannot be encoded still records the row', () async {
      create();
      await log.enableAppFile();
      await log.open('data');
      log.logData('data', 'BAD', data: {'a': 1, 'b': Hostile()});
      await log.flush();

      final row = lines(log.dataLogPath('data')!).single.split('\t');
      final payload = jsonDecode(row[2]) as Map;
      expect(row[1], 'BAD');
      expect(payload['_keys'], ['a', 'b']);
      expect(payload, contains('_encode_error'));
      expect(File(log.appLogPath!).readAsStringSync(), contains('SEVERE'));
    });

    test('uses a custom toEncodable', () async {
      create(toEncodable: (value) => 'custom');
      await log.open('data');
      log.logData('data', 'E', data: {'v': Unencodable()});
      await log.flush();
      expect(
        lines(log.dataLogPath('data')!).single,
        contains('{"v":"custom"}'),
      );
    });

    test('uses a custom format', () async {
      create();
      const format = RowFormat(
        extension: 'txt',
        formatter: upperCaseFormatter,
        joinFields: joinTsv,
      );
      await log.open('data', format: format);
      log.logData('data', 'shout', data: [1, 2]);
      await log.flush();
      expect(log.dataLogPath('data'), endsWith('.txt'));
      expect(lines(log.dataLogPath('data')!).single, 'SHOUT|[1,2]');
    });

    test('opening an unwritable path throws', () async {
      create();
      final blocker = File(p.join(temp.path, 'blocker'))
        ..writeAsStringSync('x');
      await expectLater(
        log.open('data', path: p.join(blocker.path, 'inside.tsv')),
        throwsA(isA<FileSystemException>()),
      );
      expect(log.isOpen('data'), isFalse);
    });
  });

  group('context', () {
    const columns = ['session', 'phase', 'round', 'trial', 'node', 'team'];

    List<String> lastRow() => lines(log.dataLogPath('data')!).last.split('\t');

    test('columns are present and empty when nothing is set', () async {
      create(contextColumns: columns);
      await log.open('data');
      log.logData('data', 'E');
      await log.flush();
      expect(lastRow(), hasLength(10));
      expect(lastRow().sublist(3), everyElement(isEmpty));
    });

    test('there are no trailing columns without context columns', () async {
      create();
      await log.open('data');
      log.logData('data', 'E');
      await log.flush();
      expect(lastRow(), hasLength(4));
    });

    test(
      'carries values, keeps the rest on update, and clears on null',
      () async {
        create(contextColumns: columns, clock: () => 7.0);
        await log.open('data');
        log.updateContext({
          'session': 'S1',
          'node': 'player_ab12cd34',
          'team': 1,
        });
        log.updateContext({'phase': 'joint_r2_t1', 'round': 2, 'trial': 1});
        log.logData('data', 'A');
        log.updateContext({'phase': 'survey', 'round': null, 'trial': null});
        log.logData('data', 'B');
        await log.flush();

        final written = lines(
          log.dataLogPath('data')!,
        ).map((l) => l.split('\t'));
        expect(written.first.sublist(1), [
          'A',
          '{}',
          '7.0',
          'S1',
          'joint_r2_t1',
          '2',
          '1',
          'player_ab12cd34',
          '1',
        ]);
        expect(written.last.sublist(4), [
          'S1',
          'survey',
          '',
          '',
          'player_ab12cd34',
          '1',
        ]);
        expect(log.context['phase'], 'survey');
        expect(log.context.toMap()['team'], '1');
      },
    );

    test('a value cannot break out of its column', () async {
      create(contextColumns: ['a', 'b']);
      await log.open('data');
      log.updateContext({'a': 'x\ty', 'b': 'z'});
      log.logData('data', 'E');
      await log.flush();
      expect(lastRow().sublist(4), [r'x\ty', 'z']);
    });

    test('rejects unknown and mismatched columns', () {
      create(contextColumns: ['a']);
      expect(() => log.updateContext({'b': 1}), throwsArgumentError);
      expect(() => log.context = RowContext(['a', 'b']), throwsArgumentError);
      expect(() => RowContext(['a', 'a']), throwsArgumentError);
      log.context = log.context.merge({'a': 1}).cleared();
      expect(log.context['a'], '');
    });
  });

  group('rotation and files', () {
    test('rotates without losing or duplicating rows', () async {
      create(bufferSize: 100);
      await log.enableAppFile();
      await log.open('data');
      final appPath = log.appLogPath!;
      final dataPath = log.dataLogPath('data')!;

      final rotated = <RotatedLogs>[];
      var next = 0;
      for (var round = 0; round < 3; round++) {
        for (var i = 0; i < 1000; i++) {
          log.logData('data', 'E', data: {'i': next++});
        }
        log.info('round $round');
        rotated.add(await log.rotateAll());
        // Rotated names are stamped to the microsecond.
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      log.logData('data', 'E', data: {'i': next++});
      await log.flush();

      // Logging continues at the same paths.
      expect(log.appLogPath, appPath);
      expect(log.dataLogPath('data'), dataPath);
      expect(rotated.map((r) => r.dataLogs['data']).toSet(), hasLength(3));
      expect(rotated.first.all, hasLength(2));

      final all = [
        for (final r in rotated) ...lines(r.dataLogs['data']!),
        ...lines(dataPath),
      ];
      expect(all, hasLength(3001));
      for (var i = 0; i < all.length; i++) {
        expect(all[i].split('\t')[2], '{"i":$i}');
      }
      for (var round = 0; round < 3; round++) {
        expect(lines(rotated[round].appLog!).single, endsWith('round $round'));
      }
      expect(diagnostics, isEmpty);
    });

    test('a rotated file gets a header again', () async {
      create();
      await log.open('data', header: true);
      log.logData('data', 'A');
      final rotated = await log.rotateAll();
      log.logData('data', 'B');
      await log.flush();
      expect(lines(rotated.dataLogs['data']!), hasLength(2));
      expect(lines(log.dataLogPath('data')!), hasLength(2));
    });

    test('lists current and rotated files, and purges only rotated', () async {
      create();
      await log.enableAppFile();
      // "app" is a prefix of "app_data": files must go to the longer match.
      await log.open('app');
      await log.open('app_data');
      log.info('x');
      log.logData('app', 'A');
      log.logData('app_data', 'B');
      await log.rotateAll();
      log.logData('app_data', 'C');
      await log.flush();

      final files = await log.listFiles();
      expect(files, hasLength(6));
      expect(files.where((f) => f.isCurrent), hasLength(3));
      expect(files.where((f) => f.isAppLog), hasLength(2));
      expect(files.where((f) => f.logger == 'app'), hasLength(2));
      expect(files.where((f) => f.logger == 'app_data'), hasLength(2));

      final rotated = await log.rotatedFiles();
      expect(rotated, hasLength(3));

      // Nothing is old enough yet.
      final none = await log.purgeRotated(olderThan: const Duration(days: 1));
      expect(none.deletedCount, 0);

      final purged = await log.purgeRotated();
      expect(purged.deletedCount, 3);
      expect(purged.failedCount, 0);
      expect(purged.totalSize, greaterThan(0));
      expect(await log.rotatedFiles(), isEmpty);
      expect(rotated.any((path) => File(path).existsSync()), isFalse);
      expect(File(log.dataLogPath('app_data')!).existsSync(), isTrue);
    });

    test('files from an earlier run count as rotated', () async {
      create();
      await log.open('data');
      final earlier = log.dataLogPath('data')!;
      log.logData('data', 'OLD');
      await log.dispose();

      log = DataLogger(
        directory: temp.path,
        console: false,
        sessionStamp: 'second-run',
      );
      await log.open('data');
      expect(await log.rotatedFiles(), [earlier]);
    });
  });

  group('other isolates', () {
    test('rows from several isolates all reach the same file', () async {
      create(bufferSize: 256);
      await log.enableAppFile();
      await log.open('data');
      const workers = 4;
      const rows = 5000;

      final running = [
        for (var w = 0; w < workers; w++) runWorker(log.handle, w, rows),
      ];
      for (var i = 0; i < rows; i++) {
        log.logData('data', 'ROW', data: {'worker': -1, 'i': i});
      }
      await Future.wait(running);
      await log.flush();

      final next = <int, int>{};
      for (final line in lines(log.dataLogPath('data')!)) {
        final fields = line.split('\t');
        expect(fields, hasLength(4));
        final payload = jsonDecode(fields[2]) as Map;
        final worker = payload['worker'] as int;
        // Each isolate's own rows stay in the order it logged them.
        expect(payload['i'], next[worker] ?? 0);
        next[worker] = (payload['i'] as int) + 1;
      }
      expect(next, {for (var w = -1; w < workers; w++) w: rows});

      final appLines = lines(log.appLogPath!);
      expect(appLines.where((l) => l.contains('done')), hasLength(workers));
    });

    test(
      'an attached logger inherits context and cannot manage files',
      () async {
        create(contextColumns: ['session']);
        await log.open('data');
        log.updateContext({'session': 'S9'});

        final attached = DataLogger.attach(log.handle, console: false);
        expect(attached.isAttached, isTrue);
        expect(attached.context['session'], 'S9');
        expect(attached.rotateAll, throwsStateError);
        expect(() => attached.open('more'), throwsStateError);
        attached.logData('data', 'VIA_HANDLE');
        await attached.dispose();

        // Detaching leaves the owner's files open.
        log.logData('data', 'OWNER');
        await log.flush();
        final written = lines(
          log.dataLogPath('data')!,
        ).map((l) => l.split('\t'));
        expect(written.map((r) => r[1]), ['VIA_HANDLE', 'OWNER']);
        expect(written.first[4], 'S9');
      },
    );
  });

  group('when things go wrong', () {
    test('a formatter that throws costs the layout, not the row', () async {
      create();
      await log.open('data', format: formatWith(fragileFormatter));
      log.logData('data', 'BEFORE');
      log.logData('data', 'THROW');
      log.logData('data', 'AFTER');
      await log.flush();

      final events = lines(
        log.dataLogPath('data')!,
      ).map((l) => l.split('\t')[1]);
      expect(events, ['BEFORE', 'THROW', 'AFTER']);
      expect(diagnostics.single, contains('formatter threw'));
    });

    test('a writer that dies is reported, and nothing hangs', () async {
      create(bufferSize: 1);
      await log.open('data', format: formatWith(fatalFormatter));
      await log.open('other');
      final path = log.dataLogPath('data')!;
      log.logData('data', 'BEFORE');
      await log.flush();

      log.logData('data', 'DIE');
      final watch = Stopwatch()..start();
      await log.flush();
      // The flush ends with the writer, not with the five-second timeout.
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(log.isOpen('data'), isFalse);
      expect(diagnostics.single, contains('stopped unexpectedly'));

      // Further rows are dropped quietly; other loggers carry on.
      log.logData('data', 'AFTER');
      log.logData('other', 'FINE');
      await log.flush();
      expect(lines(path).map((l) => l.split('\t')[1]), ['BEFORE']);
      expect(lines(log.dataLogPath('other')!), hasLength(1));
      expect(await log.rotateAll(), isA<RotatedLogs>());
    });

    test('a flush that times out returns, and the rows still land', () async {
      create(bufferSize: 1, timeout: const Duration(milliseconds: 150));
      await log.open('data', format: formatWith(slowFormatter));
      log.logData('data', 'SLOW');
      log.logData('data', 'NEXT');

      final watch = Stopwatch()..start();
      await log.flush();
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
      expect(diagnostics.single, contains('timed out'));

      await Future<void>.delayed(const Duration(milliseconds: 700));
      await log.flush();
      expect(lines(log.dataLogPath('data')!), hasLength(2));
      expect(diagnostics, hasLength(1));
    });

    test('closing a stalled writer gives up after the timeout', () async {
      create(bufferSize: 1, timeout: const Duration(milliseconds: 150));
      await log.open('data', format: formatWith(slowFormatter));
      log.logData('data', 'SLOW');
      final watch = Stopwatch()..start();
      await log.close('data');
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
      expect(diagnostics.single, contains('to close'));
    });

    test('an attached logger outlives its owner without hanging', () async {
      create();
      await log.open('data');
      final attached = DataLogger.attach(
        log.handle,
        console: false,
        timeout: const Duration(milliseconds: 150),
      );
      await log.close('data');

      attached.logData('data', 'INTO_THE_VOID');
      await attached.flush();
      await attached.dispose();
    });
  });

  group('memory-backed', () {
    test('buffers rows until taken', () async {
      create(memory: true, contextColumns: ['who']);
      await log.enableAppFile();
      await log.open('data', header: true);
      expect(log.isMemoryBacked, isTrue);
      expect(log.dataLogPath('data'), isNull);

      log.updateContext({'who': 'me'});
      log.info('hello');
      log.logData('data', 'A', data: {'n': 1});
      await log.flush();

      final text = const LineSplitter().convert(log.takeBuffered('data'));
      expect(text.first, 'timestamp\tevent\tdata\tclock\twho');
      expect(text.last.split('\t').sublist(1), ['A', '{"n":1}', '', 'me']);
      expect(log.takeBufferedAppLog(), contains('app: hello'));
      // Taking clears.
      expect(
        const LineSplitter().convert(log.takeBuffered('data')),
        hasLength(1),
      );
    });

    test('drops the oldest rows past the cap, and says so once', () async {
      create(memory: true, maxBufferedRows: 10, bufferSize: 1);
      await log.open('data');
      for (var i = 0; i < 25; i++) {
        log.logData('data', 'E$i');
      }
      final rows = const LineSplitter().convert(log.takeBuffered('data'));
      expect(rows, hasLength(10));
      expect(rows.first, contains('E15'));
      expect(diagnostics, hasLength(1));
    });

    test('has no files or handle', () async {
      create(memory: true);
      await log.open('data');
      expect(log.rotateAll, throwsUnsupportedError);
      expect(log.listFiles, throwsUnsupportedError);
      expect(() => log.handle, throwsUnsupportedError);
      expect(() => log.takeBuffered('missing'), throwsArgumentError);
    });
  });

  test('instance is unset until assigned and cleared on dispose', () async {
    create();
    expect(DataLogger.hasInstance, isFalse);
    expect(() => DataLogger.instance, throwsStateError);
    DataLogger.instance = log;
    expect(DataLogger.instance, same(log));
    await log.dispose();
    expect(DataLogger.hasInstance, isFalse);
  });
}
