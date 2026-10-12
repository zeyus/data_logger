@TestOn('browser')
library;

import 'dart:convert';

import 'package:data_logger/data_logger.dart';
import 'package:test/test.dart';

void main() {
  test('logs to memory on the web, whatever directory is given', () async {
    final log = DataLogger(
      directory: '/ignored',
      console: false,
      contextColumns: ['session'],
      clock: () => 1.5,
    );
    expect(log.isMemoryBacked, isTrue);

    await log.enableAppFile();
    await log.open('data', header: true);
    log.updateContext({'session': 'S1'});
    log.info('hello');
    log.logData('data', 'PRESS', data: {'x': 1, 'at': DateTime.utc(2026)});
    await log.flush();

    final rows = const LineSplitter().convert(log.takeBuffered('data'));
    expect(rows, hasLength(2));
    expect(rows.last.split('\t').sublist(1), [
      'PRESS',
      '{"x":1,"at":"2026-01-01T00:00:00.000Z"}',
      '1.5',
      'S1',
    ]);
    expect(log.takeBufferedAppLog(), contains('app: hello'));
    expect(log.rotateAll, throwsUnsupportedError);
    expect(() => log.handle, throwsUnsupportedError);
    await log.dispose();
  });
}
