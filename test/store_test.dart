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
            'payload': {'name': 'a'},
          },
        ],
      ),
    );

    final loaded = await FileQueueStore(store.file).load();
    expect(loaded!.deviceId, 'device');
    expect(loaded.queue.single['type'], 'track');
    expect(File('${store.file.path}.tmp').existsSync(), isFalse);
  });

  test('a corrupt or foreign file reads as nothing stored', () async {
    final file = File('${dir.path}/queue.json');

    file.writeAsStringSync('{not json');
    expect(await FileQueueStore(file).load(), isNull);

    file.writeAsStringSync('{"queue": []}');
    expect(await FileQueueStore(file).load(), isNull);
  });

  test('items that are not events are skipped', () {
    final state = StoredState.tryParse({
      'deviceId': 'd',
      'queue': [
        'junk',
        {'type': 'track'},
      ],
    });
    expect(state!.queue, hasLength(1));
  });
}
