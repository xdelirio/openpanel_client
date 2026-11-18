import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openpanel_client/openpanel_client.dart';
import 'package:openpanel_client/src/client.dart'
    show sendTimestamp, trackEndpoint;

const _context = DeviceContext(
  os: 'Android',
  osVersion: '15',
  model: 'Pixel 9',
  brand: 'Google',
  kind: DeviceKind.mobile,
  appName: 'demo',
  appVersion: '1.2.0',
  buildNumber: '42',
);

/// A server that answers each request with the next status in [statuses]
/// (the last one repeats) and keeps what it received.
class _Server {
  _Server([this.statuses = const [200]]);

  final List<int> statuses;
  final List<http.Request> requests = [];

  List<Map<String, Object?>> get bodies => [
    for (final r in requests) jsonDecode(r.body) as Map<String, Object?>,
  ];

  late final client = MockClient((request) async {
    requests.add(request);
    final i = requests.length - 1;
    final status = statuses[i < statuses.length ? i : statuses.length - 1];
    return http.Response('{"deviceId":"d","sessionId":"s"}', status);
  });
}

OpenPanel _panel(
  _Server server, {
  QueueStore? store,
  DateTime Function()? clock,
  int maxQueue = 1000,
  String? secret,
}) => OpenPanel(
  apiUrl: Uri.parse('https://op.example.com/api/'),
  clientId: 'client',
  clientSecret: secret,
  context: _context,
  store: store,
  httpClient: server.client,
  maxQueue: maxQueue,
  minBackoff: const Duration(milliseconds: 5),
  maxBackoff: const Duration(milliseconds: 20),
  persistDelay: Duration.zero,
  clock: clock,
);

/// Lets the queue run until it is empty or [timeout] passes.
Future<void> _settle(OpenPanel panel, {Duration? timeout}) async {
  final end = DateTime.now().add(timeout ?? const Duration(seconds: 2));
  while (panel.pending.isNotEmpty && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  await panel.flush();
}

Map<String, Object?> _props(Map<String, Object?> body) =>
    (body['payload']! as Map<String, Object?>)['properties']!
        as Map<String, Object?>;

void main() {
  test('the track endpoint keeps the API path, slash or not', () {
    for (final base in ['https://h/api', 'https://h/api/']) {
      expect(trackEndpoint(Uri.parse(base)).toString(), 'https://h/api/track');
    }
    expect(trackEndpoint(Uri.parse('https://h')).toString(), 'https://h/track');
  });

  test('track posts to /track with the client headers', () async {
    final server = _Server();
    final panel = _panel(server, secret: 'secret');

    panel.track('play', properties: {'title': 'x'});
    await _settle(panel);

    final request = server.requests.single;
    expect(request.url.toString(), 'https://op.example.com/api/track');
    expect(request.method, 'POST');
    expect(request.headers['openpanel-client-id'], 'client');
    expect(request.headers['openpanel-client-secret'], 'secret');
    expect(request.headers['openpanel-sdk-name'], 'dart');
    expect(request.headers['user-agent'], 'demo/1.2.0 (Android 15; Pixel 9)');
    expect(request.headers['content-type'], startsWith('application/json'));

    final body = server.bodies.single;
    expect(body['type'], 'track');
    expect((body['payload']! as Map)['name'], 'play');
    expect(_props(body)['title'], 'x');
  });

  test('no secret header when there is no secret', () async {
    final server = _Server();
    final panel = _panel(server)..track('a');
    await _settle(panel);
    expect(
      server.requests.single.headers.containsKey('openpanel-client-secret'),
      isFalse,
    );
  });

  test('every event states its device, release, install and time', () async {
    final server = _Server();
    final at = DateTime.utc(2026, 11, 18, 12, 30);
    final panel = _panel(server, clock: () => at)..track('a');
    await _settle(panel);

    final props = _props(server.bodies.single);
    expect(props, containsPair('__os', 'Android'));
    expect(props, containsPair('__osVersion', '15'));
    expect(props, containsPair('__model', 'Pixel 9'));
    expect(props, containsPair('__brand', 'Google'));
    expect(props, containsPair('__device', 'mobile'));
    expect(props, containsPair('__version', '1.2.0'));
    expect(props, containsPair('__buildNumber', '42'));
    // Fresh: the server stamps it with its own clock.
    expect(props.containsKey('__timestamp'), isFalse);
    expect(props['__deviceId'], panel.deviceId);
    expect(panel.deviceId, matches(RegExp(r'^[0-9a-f-]{36}$')));
  });

  test('an event sent late keeps the time it happened', () async {
    final server = _Server([503, 200]);
    var now = DateTime.utc(2026, 1, 1, 8);
    final panel = _panel(server, clock: () => now)..track('offline');
    now = DateTime.utc(2026, 1, 1, 9);
    await _settle(panel);

    expect(server.requests, hasLength(2));
    expect(
      _props(server.bodies.last)['__timestamp'],
      '2026-01-01T08:00:00.000Z',
    );
  });

  test(
    'identify files later events under the profile; reset stops it',
    () async {
      final server = _Server();
      final panel = _panel(server)
        ..identify('user-1')
        ..track('a')
        ..reset()
        ..track('b');
      await _settle(panel);

      // An id alone sends nothing: the next event creates the profile.
      expect(server.bodies.map((b) => b['type']), ['track', 'track']);
      expect((server.bodies[0]['payload']! as Map)['profileId'], 'user-1');
      expect(
        (server.bodies[1]['payload']! as Map).containsKey('profileId'),
        isFalse,
      );
    },
  );

  test('identify with traits updates the profile', () async {
    final server = _Server();
    final panel = _panel(server)
      ..identify('user-1', email: 'a@b.c', properties: {'plan': 'pro'});
    await _settle(panel);

    expect(server.bodies.single, {
      'type': 'identify',
      'payload': {
        'profileId': 'user-1',
        'email': 'a@b.c',
        'properties': {'plan': 'pro'},
      },
    });
  });

  test('increment and decrement need a profile', () async {
    final server = _Server();
    final panel = _panel(server)
      ..increment('plays')
      ..identify('u')
      ..increment('plays', value: 2)
      ..decrement('credits');
    await _settle(panel);

    expect(server.bodies, [
      {
        'type': 'increment',
        'payload': {'profileId': 'u', 'property': 'plays', 'value': 2},
      },
      {
        'type': 'decrement',
        'payload': {'profileId': 'u', 'property': 'credits', 'value': 1},
      },
    ]);
  });

  test('screen sends screen_view and tags the events after it', () async {
    final server = _Server();
    final panel = _panel(server)
      ..screen('/home')
      ..track('play');
    await _settle(panel);

    expect((server.bodies[0]['payload']! as Map)['name'], 'screen_view');
    expect(_props(server.bodies[0])['__path'], '/home');
    expect(_props(server.bodies[1])['__path'], '/home');
  });

  test('global properties go under the event\'s own', () async {
    final server = _Server();
    final panel = _panel(server)
      ..setGlobalProperties({'brand': 'a', 'tier': 'free'})
      ..track('x', properties: {'tier': 'pro'});
    await _settle(panel);

    expect(_props(server.bodies.single), containsPair('brand', 'a'));
    expect(_props(server.bodies.single), containsPair('tier', 'pro'));
  });

  test('sends in order and retries a server error before moving on', () async {
    final server = _Server([500, 429, 200]);
    final panel = _panel(server)
      ..track('1')
      ..track('2');
    await _settle(panel);

    final names = [
      for (final b in server.bodies) (b['payload']! as Map)['name'],
    ];
    expect(names, ['1', '1', '1', '2']);
    expect(panel.pending, isEmpty);
  });

  test('a refused event is dropped, not retried', () async {
    final server = _Server([400, 422, 200]);
    final panel = _panel(server)
      ..track('1')
      ..track('2')
      ..track('3');
    await _settle(panel);

    expect(server.requests, hasLength(3));
    expect(panel.pending, isEmpty);
  });

  test('401 and 403 pause the queue instead of emptying it', () async {
    final server = _Server([401, 403, 200]);
    final panel = _panel(server)
      ..track('1')
      ..track('2');
    await _settle(panel);

    final names = [
      for (final b in server.bodies) (b['payload']! as Map)['name'],
    ];
    expect(names, ['1', '1', '1', '2']);
  });

  test('reset keeps the current screen', () async {
    final server = _Server();
    final panel = _panel(server)
      ..screen('/profiles')
      ..identify('u')
      ..reset()
      ..track('profile_selected');
    await _settle(panel);

    expect(_props(server.bodies.last)['__path'], '/profiles');
  });

  test('opted out at launch, what the last launch left is discarded', () async {
    final store = MemoryQueueStore(
      const StoredState(
        deviceId: 'd',
        queue: [
          {
            'type': 'track',
            'payload': {'name': 'old'},
          },
        ],
      ),
    );
    final server = _Server();
    final panel = OpenPanel(
      apiUrl: Uri.parse('https://op.example.com/'),
      clientId: 'c',
      context: _context,
      store: store,
      httpClient: server.client,
      enabled: false,
    );
    await panel.ready;
    await panel.dispose();

    expect(panel.pending, isEmpty);
    expect(store.state!.queue, isEmpty);
    expect(server.requests, isEmpty);
  });

  test('dispose waits for the store to hold the final queue', () async {
    final store = MemoryQueueStore();
    final server = _Server();
    final panel = _panel(server, store: store);
    for (var i = 0; i < 30; i++) {
      panel.track('$i');
    }
    await _settle(panel);
    await panel.dispose();

    expect(server.requests, hasLength(30));
    expect(store.state!.queue, isEmpty);
  });

  test('an event added as a drain ends is still sent', () async {
    final server = _Server();
    final panel = _panel(server)..track('1');
    await panel.ready;
    // Lands while the first drain is finishing.
    unawaited(Future<void>.microtask(() => panel.track('2')));
    await _settle(panel);

    expect(server.requests, hasLength(2));
  });

  test('a network failure keeps the event for later', () async {
    var fail = true;
    final requests = <http.Request>[];
    final panel = OpenPanel(
      apiUrl: Uri.parse('https://op.example.com/'),
      clientId: 'c',
      context: _context,
      minBackoff: const Duration(milliseconds: 5),
      maxBackoff: const Duration(milliseconds: 10),
      httpClient: MockClient((r) async {
        requests.add(r);
        if (fail) throw http.ClientException('offline');
        return http.Response('', 202);
      }),
    )..track('a');
    await panel.ready;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(panel.pending, hasLength(1));

    fail = false;
    await _settle(panel);
    expect(panel.pending, isEmpty);
    expect(requests.length, greaterThan(1));
  });

  test('a value that is not JSON is dropped at the call', () async {
    final server = _Server();
    final panel = _panel(server)
      ..track('bad', properties: {'when': DateTime(2026)})
      ..track('good');
    await _settle(panel);

    expect(server.bodies, hasLength(1));
    expect((server.bodies.single['payload']! as Map)['name'], 'good');
  });

  test('a full queue drops the oldest', () async {
    final store = MemoryQueueStore();
    final server = _Server([503]);
    final panel = _panel(server, store: store, maxQueue: 2)
      ..track('1')
      ..track('2')
      ..track('3');
    await panel.ready;

    expect(
      [for (final b in panel.pending) (b['payload']! as Map)['name']],
      ['2', '3'],
    );
    await panel.dispose();
  });

  test('pending events and the device id survive a restart', () async {
    final store = MemoryQueueStore();
    final down = _Server([503]);
    final first = _panel(down, store: store)..track('queued');
    await first.ready;
    await first.dispose();

    final up = _Server();
    final second = _panel(up, store: store);
    await _settle(second);
    await second.dispose();

    expect(second.deviceId, first.deviceId);
    expect((up.bodies.single['payload']! as Map)['name'], 'queued');
    expect(store.state!.queue, isEmpty);
  });

  test('events recorded while loading go after the stored ones', () async {
    final loaded = Completer<StoredState?>();
    final store = _SlowStore(loaded.future);
    final server = _Server();
    final panel = _panel(server, store: store)..track('new');

    loaded.complete(
      const StoredState(
        deviceId: 'stored-device',
        queue: [
          {
            'type': 'track',
            'payload': {'name': 'old', 'properties': <String, Object?>{}},
          },
        ],
      ),
    );
    await _settle(panel);

    expect(
      [for (final b in server.bodies) (b['payload']! as Map)['name']],
      ['old', 'new'],
    );
    expect(_props(server.bodies.last)['__deviceId'], 'stored-device');
  });

  test(
    'a 401 for the event itself is final; a 401 for the client is not',
    () async {
      var i = 0;
      final requests = <String>[];
      final panel =
          OpenPanel(
              apiUrl: Uri.parse('https://op.example.com/'),
              clientId: 'c',
              context: _context,
              persistDelay: Duration.zero,
              minBackoff: const Duration(milliseconds: 5),
              maxBackoff: const Duration(milliseconds: 10),
              httpClient: MockClient((r) async {
                final name =
                    ((jsonDecode(r.body) as Map)['payload'] as Map)['name'];
                requests.add('$name');
                return switch (i++) {
                  0 => http.Response(
                    'Ingestion: Profile id is blocked by project filter',
                    401,
                  ),
                  1 => http.Response('Ingestion: Invalid cors or secret', 401),
                  _ => http.Response('', 202),
                };
              }),
            )
            ..track('filtered')
            ..track('kept');
      await _settle(panel);

      expect(requests, ['filtered', 'kept', 'kept']);
    },
  );

  test('an old event keeps its time, moved by the server clock offset', () {
    final now = DateTime.utc(2026, 1, 1, 12);
    final recorded = now.subtract(const Duration(hours: 1)).toIso8601String();

    expect(
      sendTimestamp(recorded: recorded, now: now),
      '2026-01-01T11:00:00.000Z',
    );
    expect(
      sendTimestamp(
        recorded: recorded,
        now: now,
        clockOffset: const Duration(minutes: 30),
      ),
      '2026-01-01T11:30:00.000Z',
    );
    // A second of skew is noise, not an offset.
    expect(
      sendTimestamp(
        recorded: recorded,
        now: now,
        clockOffset: const Duration(seconds: 1),
      ),
      '2026-01-01T11:00:00.000Z',
    );
    // Fresh, from the future, or unreadable: the server's arrival time.
    expect(sendTimestamp(recorded: now.toIso8601String(), now: now), isNull);
    expect(
      sendTimestamp(
        recorded: now.add(const Duration(hours: 1)).toIso8601String(),
        now: now,
      ),
      isNull,
    );
    expect(sendTimestamp(recorded: 'x', now: now), isNull);
    // Recorded before the clock was set (a TV box that boots in 1970).
    expect(
      sendTimestamp(recorded: DateTime.utc(1970).toIso8601String(), now: now),
      isNull,
    );
  });

  test('the clock offset is learnt from the Date header', () async {
    var now = DateTime.utc(2026, 1, 1, 12);
    final bodies = <Map<String, Object?>>[];
    final panel = OpenPanel(
      apiUrl: Uri.parse('https://op.example.com/'),
      clientId: 'c',
      context: _context,
      clock: () => now,
      persistDelay: Duration.zero,
      httpClient: MockClient((r) async {
        bodies.add(jsonDecode(r.body) as Map<String, Object?>);
        // The server is an hour ahead of this device.
        return http.Response(
          '',
          202,
          headers: {'date': HttpDate.format(now.add(const Duration(hours: 1)))},
        );
      }),
    )..track('first');
    await _settle(panel);

    // Recorded now, sent ten minutes later (it waited in the queue).
    panel.setEnabled(false);
    panel.setEnabled(true);
    final recordedAt = now;
    panel.track('late');
    final late = panel.pending.single;
    now = now.add(const Duration(minutes: 10));
    await _settle(panel);

    expect(_props(late)['__timestamp'], recordedAt.toIso8601String());
    expect(_props(bodies.last)['__timestamp'], '2026-01-01T13:00:00.000Z');
  });

  test(
    'names, profile ids and counters the server would refuse stay out',
    () async {
      final server = _Server();
      final panel = _panel(server)
        ..track('')
        ..track('x' * 81)
        ..track('session_start')
        ..track('line\nbreak')
        ..identify('')
        ..identify('u', email: 'not-an-email', avatar: 'ftp://x/a.png')
        ..increment('plays', value: 0)
        ..decrement('plays', value: -1)
        ..track('ok');
      await _settle(panel);

      expect(server.bodies.map((b) => b['type']), ['track']);
      expect((server.bodies.single['payload']! as Map)['profileId'], 'u');
    },
  );

  test('a logger that throws does not break the client', () async {
    final server = _Server();
    final panel = OpenPanel(
      apiUrl: Uri.parse('https://op.example.com/'),
      clientId: 'c',
      context: _context,
      httpClient: server.client,
      persistDelay: Duration.zero,
      logger: (_) => throw StateError('logger'),
    )..track('');
    panel.track('ok');
    await _settle(panel);
    expect(server.requests, hasLength(1));
  });

  test(
    'a store out of reach is left alone and events stay in memory',
    () async {
      final store = _BrokenStore();
      final server = _Server([503]);
      final panel = _panel(server, store: store)..track('a');
      await panel.ready;
      await panel.dispose();

      expect(store.saves, 0);
      expect(panel.pending, hasLength(1));
      expect(panel.deviceId, isNotEmpty);
    },
  );

  test('opting out mid-request schedules no retry', () async {
    final gate = Completer<http.Response>();
    final panel = OpenPanel(
      apiUrl: Uri.parse('https://op.example.com/'),
      clientId: 'c',
      context: _context,
      persistDelay: Duration.zero,
      httpClient: MockClient((_) => gate.future),
    )..track('a');
    await panel.ready;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    panel.setEnabled(false);
    gate.complete(http.Response('', 503));
    await panel.flush();

    expect(panel.pending, isEmpty);
    await panel.dispose();
  });

  test('a send that hangs past the backstop is retried, not held', () async {
    var calls = 0;
    final panel = OpenPanel(
      apiUrl: Uri.parse('https://op.example.com/'),
      clientId: 'c',
      context: _context,
      persistDelay: Duration.zero,
      requestTimeout: const Duration(milliseconds: 10),
      minBackoff: const Duration(milliseconds: 5),
      maxBackoff: const Duration(milliseconds: 5),
      // Ignores the abort: the first request never answers.
      httpClient: MockClient((_) {
        calls++;
        return calls == 1
            ? Completer<http.Response>().future
            : Future.value(http.Response('', 202));
      }),
    )..track('a');
    await _settle(panel);

    expect(panel.pending, isEmpty);
    expect(calls, 2);
  });

  test('persist writes now, without waiting for the delay', () async {
    final store = MemoryQueueStore();
    final panel = OpenPanel(
      apiUrl: Uri.parse('https://op.example.com/'),
      clientId: 'c',
      context: _context,
      store: store,
      persistDelay: const Duration(hours: 1),
      httpClient: _Server([503]).client,
    );
    await panel.ready;
    panel.track('a');
    await panel.persist();

    expect(store.state!.queue, hasLength(1));
    await panel.dispose();
  });

  test('a second instance reports as the same install', () async {
    final panel = _panel(_Server(), store: _LockedStore());
    await panel.ready;
    expect(panel.deviceId, 'held-install');
    await panel.dispose();
  });

  test('turning it off discards what is pending and records nothing', () async {
    final server = _Server([503]);
    final panel = _panel(server)..track('a');
    await panel.ready;
    panel.setEnabled(false);
    panel.track('b');

    expect(panel.pending, isEmpty);
    await panel.dispose();
  });
}

class _LockedStore extends QueueStore {
  @override
  Future<StoredState?> load() async =>
      throw const StoreLockedException('x', deviceId: 'held-install');

  @override
  Future<void> save(StoredState state) async {}
}

class _BrokenStore extends QueueStore {
  int saves = 0;

  @override
  Future<StoredState?> load() async =>
      throw const FileSystemException('locked');

  @override
  Future<void> save(StoredState state) async => saves++;
}

class _SlowStore extends QueueStore {
  _SlowStore(this._load);

  final Future<StoredState?> _load;
  StoredState? saved;

  @override
  Future<StoredState?> load() => _load;

  @override
  Future<void> save(StoredState state) async => saved = state;
}
