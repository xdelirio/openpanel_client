import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:openpanel_client/src/device_context.dart';
import 'package:openpanel_client/src/store.dart';

/// Reported in `openpanel-sdk-name` / `openpanel-sdk-version`.
const sdkName = 'dart';
const sdkVersion = '0.1.0';

/// A client for OpenPanel's `/track` API.
///
/// Every call is recorded as it happens and returns at once: the event is
/// stamped with its time, queued, stored, and sent in the background, in
/// order. A failure to send is retried later with backoff; nothing here
/// throws or awaits the network, because telemetry must never be able to
/// break what it measures.
///
/// The server has no batch endpoint, so events go one request each.
class OpenPanel {
  OpenPanel({
    required Uri apiUrl,
    required this.clientId,
    this.clientSecret,
    required this.context,
    QueueStore? store,
    http.Client? httpClient,
    this.maxQueue = 1000,
    bool enabled = true,
    this.minBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(minutes: 5),
    this.requestTimeout = const Duration(seconds: 15),
    DateTime Function()? clock,
    this.logger,
  }) : _endpoint = trackEndpoint(apiUrl),
       _store = store ?? MemoryQueueStore(),
       _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null,
       _enabled = enabled,
       _clock = clock ?? DateTime.now {
    _ready = _restore();
  }

  final String clientId;

  /// Only needed when the project's client requires it. An app ships it in
  /// its binary, so it is not a secret there; a write-only client is.
  final String? clientSecret;

  final DeviceContext context;

  /// Beyond this many pending events the oldest are dropped.
  final int maxQueue;

  final Duration minBackoff;
  final Duration maxBackoff;
  final Duration requestTimeout;

  /// Receives what the client did and why an event was dropped.
  final void Function(String message)? logger;

  final Uri _endpoint;
  final QueueStore _store;
  final http.Client _http;
  final bool _ownsHttp;
  final DateTime Function() _clock;

  late final Future<void> _ready;
  final List<Map<String, Object?>> _queue = [];
  String _deviceId = '';
  String? _profileId;
  String? _path;
  Map<String, Object?> _global = const {};
  bool _enabled;
  bool _disposed = false;

  Future<void>? _sending;
  bool _draining = false;
  Timer? _retry;
  int _attempt = 0;

  Future<void>? _saving;
  bool _saveAgain = false;

  /// The install's id, stable across launches. Empty until the store loads.
  String get deviceId => _deviceId;

  String? get profileId => _profileId;

  bool get enabled => _enabled;

  /// Events recorded and not yet accepted by the server, oldest first.
  List<Map<String, Object?>> get pending => List.unmodifiable(_queue);

  /// Completes once what the store held is loaded back.
  Future<void> get ready => _ready;

  /// Records [name] with [properties]. Values must be JSON: strings, numbers,
  /// booleans, null, and lists or maps of those.
  void track(String name, {Map<String, Object?>? properties}) {
    _enqueue('track', {
      'name': name,
      'profileId': ?_profileId,
      'properties': {
        ..._global,
        ...context.toProperties(),
        ...?properties,
        '__timestamp': _clock().toUtc().toIso8601String(),
        '__path': ?_path,
      },
    });
  }

  /// Records a `screen_view` of [path], and files the events that follow
  /// under it until the next one.
  void screen(String path, {Map<String, Object?>? properties}) {
    _path = path;
    track('screen_view', properties: properties);
  }

  /// Files the events that follow under [profileId] (the app's user id), and
  /// updates the profile when any trait is given. With only the id nothing
  /// is sent: the next event creates the profile.
  void identify(
    String profileId, {
    String? firstName,
    String? lastName,
    String? email,
    String? avatar,
    Map<String, Object?>? properties,
  }) {
    _profileId = profileId;
    final traits = {
      'firstName': ?firstName,
      'lastName': ?lastName,
      'email': ?email,
      'avatar': ?avatar,
      if (properties != null && properties.isNotEmpty) 'properties': properties,
    };
    if (traits.isEmpty) return;
    _enqueue('identify', {'profileId': profileId, ...traits});
  }

  /// Stops filing events under a profile: sign-out, or another account. The
  /// device id stays — it is still the same install — and so does the
  /// current screen, which changing accounts does not leave.
  void reset() {
    _profileId = null;
  }

  /// Adds [value] to a numeric [property] of the current profile. Does
  /// nothing before [identify].
  void increment(String property, {num value = 1}) =>
      _profileCounter('increment', property, value);

  /// Subtracts [value] from a numeric [property] of the current profile.
  void decrement(String property, {num value = 1}) =>
      _profileCounter('decrement', property, value);

  /// Properties added to every event from now on, beneath the event's own.
  void setGlobalProperties(Map<String, Object?> properties) {
    _global = {..._global, ...properties};
  }

  /// Turning it off is an opt-out: what was pending is discarded and nothing
  /// is recorded until it is turned back on.
  void setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) {
      _retry?.cancel();
      _attempt = 0;
      _queue.clear();
      _persist();
    } else {
      unawaited(flush());
    }
  }

  /// Sends what is pending now, without waiting for the retry timer. Call it
  /// when the app comes back to the foreground or the network returns.
  Future<void> flush() async {
    await _ready;
    if (_disposed || !_enabled) return;
    _retry?.cancel();
    // A flag cleared by the drain itself, in the same step as its last look
    // at the queue: an event added after that look starts a new drain
    // instead of joining one that has already finished.
    if (_draining) return _sending;
    _draining = true;
    return _sending = _drain();
  }

  /// Stops sending and waits for the store to be written. Pending events stay
  /// stored for the next launch.
  Future<void> dispose() async {
    _disposed = true;
    _retry?.cancel();
    await _ready;
    await _sending;
    // A save can schedule a follow-up one with what changed meanwhile.
    while (_saving != null) {
      await _saving;
    }
    if (_ownsHttp) _http.close();
  }

  void _profileCounter(String type, String property, num value) {
    final profileId = _profileId;
    if (profileId == null) return;
    _enqueue(type, {
      'profileId': profileId,
      'property': property,
      'value': value,
    });
  }

  void _enqueue(String type, Map<String, Object?> payload) {
    if (!_enabled || _disposed) return;
    final Map<String, Object?> body;
    try {
      // Through JSON and back now, not at send time: an unencodable value
      // would otherwise stall the queue behind it on every retry, and the
      // copy keeps a list or map the caller mutates later out of the event.
      body =
          jsonDecode(jsonEncode({'type': type, 'payload': payload}))
              as Map<String, Object?>;
    } on Object catch (e) {
      _log('dropped $type: properties are not JSON ($e)');
      return;
    }
    _queue.add(body);
    _trim();
    _persist();
    // While a retry is scheduled the server is known to be unreachable: the
    // new event waits its turn instead of spending a request per call.
    if (_retry?.isActive != true) unawaited(flush());
  }

  void _trim() {
    final excess = _queue.length - maxQueue;
    if (excess <= 0) return;
    _queue.removeRange(0, excess);
    _log('queue full: dropped the $excess oldest events');
  }

  Future<void> _restore() async {
    StoredState? stored;
    try {
      stored = await _store.load();
    } on Object catch (e) {
      _log('store could not be read: $e');
    }
    _deviceId = stored?.deviceId ?? _newDeviceId();
    final restored = stored?.queue ?? const [];
    // Opted out (in the constructor or before this load ended): what the
    // last launch left is discarded, not kept for when it is turned back on.
    if (_enabled) {
      // What the last launch left goes first; what was recorded while
      // loading is newer.
      _queue.insertAll(0, restored);
      _trim();
    }
    if (stored == null || restored.isNotEmpty || _queue.isNotEmpty) {
      _persist();
    }
    if (_queue.isNotEmpty) unawaited(flush());
  }

  /// Sends the queue in order until it is empty or a send must wait.
  ///
  /// The store is rewritten every [_persistEvery] sends and when the drain
  /// stops, not after each one: draining a long offline backlog would
  /// otherwise rewrite the whole file per event. A crash in between sends
  /// at most that many events twice.
  Future<void> _drain() async {
    var unsaved = 0;
    try {
      while (_queue.isNotEmpty && _enabled && !_disposed) {
        final body = _queue.first;
        final outcome = await _send(body);
        if (outcome == _Outcome.retry) {
          if (!_disposed) _scheduleRetry();
          return;
        }
        _attempt = 0;
        // Not removeAt(0): setEnabled(false) may have cleared the queue
        // while the request was out.
        _queue.remove(body);
        if (++unsaved >= _persistEvery) {
          unsaved = 0;
          _persist();
        }
      }
    } finally {
      _draining = false;
      if (unsaved > 0) _persist();
    }
  }

  Future<_Outcome> _send(Map<String, Object?> body) async {
    try {
      final response = await _http
          .post(
            _endpoint,
            headers: _headers,
            body: jsonEncode(_withDevice(body)),
          )
          .timeout(requestTimeout);
      final status = response.statusCode;
      if (status == 200 || status == 202) return _Outcome.sent;
      // Busy or broken server, or refused for who is asking rather than
      // what: a rotated secret, a WAF or a region block answers 401/403 to
      // every event alike, so dropping would empty the whole queue.
      if (status == 401 ||
          status == 403 ||
          status == 408 ||
          status == 429 ||
          status >= 500) {
        _log('${body['type']} got $status; retrying');
        return _Outcome.retry;
      }
      // A body the server refuses will be refused every time.
      _log('${body['type']} dropped: $status ${response.body}');
      return _Outcome.dropped;
    } on Object catch (e) {
      _log('${body['type']} not sent ($e); retrying');
      return _Outcome.retry;
    }
  }

  /// The device id goes on at send time: an event recorded before the store
  /// loaded did not have it yet, and it never changes for an install.
  Map<String, Object?> _withDevice(Map<String, Object?> body) {
    if (body['type'] != 'track') return body;
    final payload = body['payload']! as Map<String, Object?>;
    final properties = payload['properties'] as Map<String, Object?>? ?? {};
    return {
      ...body,
      'payload': {
        ...payload,
        'properties': {'__deviceId': _deviceId, ...properties},
      },
    };
  }

  Map<String, String> get _headers => {
    'content-type': 'application/json',
    'user-agent': context.userAgent,
    'openpanel-client-id': clientId,
    'openpanel-client-secret': ?clientSecret,
    'openpanel-sdk-name': sdkName,
    'openpanel-sdk-version': sdkVersion,
  };

  void _scheduleRetry() {
    // The exponent stops growing well before it could overflow: after hours
    // offline the delay sits at maxBackoff instead of wrapping around.
    final delay = minBackoff * pow(2, min(_attempt, 20));
    _attempt++;
    _retry?.cancel();
    _retry = Timer(delay > maxBackoff ? maxBackoff : delay, () {
      unawaited(flush());
    });
  }

  /// Writes the current state, coalescing bursts: while one save is out,
  /// later changes are written once by a single follow-up save.
  void _persist() {
    if (_saving != null) {
      _saveAgain = true;
      return;
    }
    _saving = _save().whenComplete(() {
      _saving = null;
      if (_saveAgain) {
        _saveAgain = false;
        _persist();
      }
    });
  }

  Future<void> _save() async {
    if (_deviceId.isEmpty) return;
    try {
      await _store.save(
        StoredState(deviceId: _deviceId, queue: List.of(_queue)),
      );
    } on Object catch (e) {
      _log('store could not be written: $e');
    }
  }

  void _log(String message) => logger?.call('[openpanel] $message');
}

enum _Outcome { sent, dropped, retry }

const _persistEvery = 20;

/// `/track` under [apiUrl], whether or not it ends in a slash: a bare
/// `resolve('track')` on `https://host/api` would drop the `api`.
@visibleForTesting
Uri trackEndpoint(Uri apiUrl) {
  final path = apiUrl.path.endsWith('/') ? apiUrl.path : '${apiUrl.path}/';
  return apiUrl.replace(path: '${path}track');
}

/// A random (v4) UUID. Its own few lines rather than a dependency.
String _newDeviceId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
