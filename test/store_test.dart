import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openpanel_client/openpanel_client.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('openpanel_store'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('FileQueueStore round-trips the state', () async {
    final store = FileQueueStore(File('${dir.path}/nested/queue.json'));
    expect(await store.load(), isNull);

    await store.save(
      const StoredState(
        deviceId: 'device',
        queue: [
          {
            'type': 'track',
            'payload': {'name': 'a', 'properties': <String, Object?>{}},
          },
        ],
      ),
    );

    await store.close();

    final again = FileQueueStore(store.file);
    final loaded = await again.load();
    await again.close();
    expect(loaded!.deviceId, 'device');
    expect(loaded.queue.single['type'], 'track');
    expect(File('${store.file.path}.tmp').existsSync(), isFalse);
  });

  test(
    'a second store on the same file is refused, with the device id',
    () async {
      final file = File('${dir.path}/queue.json');
      final first = FileQueueStore(file);
      await first.load();
      await first.save(const StoredState(deviceId: 'install', queue: []));

      final second = FileQueueStore(file);
      await expectLater(
        second.load(),
        throwsA(
          isA<StoreLockedException>().having(
            (e) => e.deviceId,
            'deviceId',
            'install',
          ),
        ),
      );

      await first.close();
      expect(await second.load(), isNotNull);
      await second.close();
    },
  );

  test('a corrupt or foreign file reads as nothing stored', () async {
    final file = File('${dir.path}/queue.json');

    Future<StoredState?> load() async {
      final store = FileQueueStore(file);
      try {
        return await store.load();
      } finally {
        await store.close();
      }
    }

    file.writeAsStringSync('{not json');
    expect(await load(), isNull);

    file.writeAsStringSync('{"queue": []}');
    expect(await load(), isNull);

    // Not even UTF-8: corrupt, not out of reach.
    file.writeAsBytesSync([0xff, 0xfe, 0x00, 0xc3]);
    expect(await load(), isNull);
  });

  test('items that are not events this client sends are skipped', () {
    final state = StoredState.tryParse({
      'deviceId': 'd',
      'queue': [
        'junk',
        {'type': 'track'},
        {
          'type': 'track',
          'payload': {'name': 'x', 'properties': 'not a map'},
        },
        {
          'type': 'alias',
          'payload': {'profileId': 'u'},
        },
        {
          'type': 'increment',
          'payload': {'profileId': 'u', 'property': 'p', 'value': '1'},
        },
        {
          'type': 'track',
          'payload': {'name': 'ok', 'properties': <String, Object?>{}},
        },
        {
          'type': 'identify',
          'payload': {'profileId': 'u'},
        },
      ],
    });
    expect(state!.queue.map((i) => i['type']), ['track', 'identify']);
  });

  test('a store that cannot be read is not taken for a first launch', () async {
    // A directory where the file should be: it exists, and reading fails.
    final file = File('${dir.path}/queue.json');
    Directory(file.path).createSync();
    expect(
      () => FileQueueStore(file).load(),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('the lock file is released on close', () async {
    final store = FileQueueStore(File('${dir.path}/queue.json'));
    await store.load();
    await store.close();
    // Reopening in the same process works once released.
    final again = FileQueueStore(store.file);
    expect(await again.load(), isNull);
    await again.close();
  });
}
