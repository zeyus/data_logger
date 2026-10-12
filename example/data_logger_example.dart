import 'dart:io';
import 'dart:isolate';

import 'package:data_logger/data_logger.dart';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('data_logger_');
  final stopwatch = Stopwatch()..start();

  final log = DataLogger(
    directory: directory.path,
    contextColumns: ['session', 'trial'],
    // Any clock better than the wall clock: here, seconds since start.
    clock: () => stopwatch.elapsedMicroseconds / 1e6,
  );
  await log.enableAppFile();
  await log.open('events', header: true);

  log.updateContext({'session': 'S01'});
  log.info('Session started');

  for (var trial = 1; trial <= 2; trial++) {
    log.updateContext({'trial': trial});
    log.logData('events', 'TRIAL_START');
    log.logData('events', 'RESPONSE', data: {'key': 'space', 'correct': true});
  }

  // Another isolate logs into the same file.
  await analyse(log.handle);

  // A checkpoint: everything so far is on disk when this returns.
  await log.flush();
  final path = log.dataLogPath('events')!;
  await log.dispose();

  print('\n$path:\n${File(path).readAsStringSync()}');
  await directory.delete(recursive: true);
}

Future<void> analyse(LogHandle handle) => Isolate.run(() async {
  final log = DataLogger.attach(handle);
  log.logData('events', 'ANALYSIS_DONE', data: {'score': 0.93});
  await log.flush();
  await log.dispose();
});
