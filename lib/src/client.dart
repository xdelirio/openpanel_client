import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate, IOException;
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:openpanel_client/src/device_context.dart';
import 'package:openpanel_client/src/store.dart';

/// Reported in `openpanel-sdk-name` / `openpanel-sdk-version`. Kept by hand
/// in step with `pubspec.yaml`.
const sdkName = 'dart';
const sdkVersion = '0.2.0';

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
    this.persistDelay = const Duration(seconds: 1),
    DateTime Function()? clock,
    this.logger,
  }) : assert(maxQueue > 0, 'maxQueue must hold at least one event'),
       _endpoint = trackEndpoint(apiUrl),
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

  /// A request still out after this is aborted and retried later.
  final Duration requestTimeout;

  /// How long changes wait before the store is written, so a burst of
  /// events — or a drain of a long backlog — is one write, not one each.
  final Duration persistDelay;

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

  /// False when the store could not be read (locked by another instance of
  /// the app, or an I/O error): this run neither restores nor overwrites it.
  bool _storeUsable = true;

  Future<void>? _sending;
  bool _draining = false;
  Completer<void>? _abortInFlight;
  Timer? _retry;
  int _attempt = 0;

  /// Server time minus device time, learnt from each response's `Date`.
  Duration? _clockOffset;

  Timer? _persistTimer;
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

  /// Records [name] with [properties].
  ///
  /// Values must be JSON (strings, numbers, booleans, lists and maps of
  /// those). The server drops `null` and empty-string values and flattens
  /// nested maps (`a.b`), at most 50 keys per map. A [name] it would refuse
  /// — empty, over 80 characters, with a line break, or one of its own
  /// (`session_start`, `session_end`) — is dropped here and logged.
  void track(String name, {Map<String, Object?>? properties}) {
    if (!isValidEventName(name)) {
      _log('dropped track: the server refuses the name "$name"');
      return;
    }
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
  /// is sent: the next event creates the profile, a moment after it arrives.
  ///
  /// An [email] that is not one and an [avatar] that is not an http(s) URL
  /// are left out, since the server would refuse the whole profile for them.
  void identify(
    String profileId, {
    String? firstName,
    String? lastName,
    String? email,
    String? avatar,
    Map<String, Object?>? properties,
  }) {
    if (profileId.isEmpty) {
      _log('identify ignored: an empty profile id would fail every event');
      return;
    }
    _profileId = profileId;
    final traits = {
      'firstName': ?firstName,
      'lastName': ?lastName,
      if (email != null && isValidEmail(email)) 'email': email,
      if (avatar != null && isValidAvatar(avatar)) 'avatar': avatar,
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

  /// Adds [value] (> 0) to a numeric [property] of the current profile.
  /// Does nothing before [identify]. The server answers 404 — and the change
  /// is lost — while a brand-new profile is still being created, so the
  /// first counter of a new user can miss.
  void increment(String property, {num value = 1}) =>
      _profileCounter('increment', property, value);

  /// Subtracts [value] (> 0) from a numeric [property] of the current
  /// profile. Same caveats as [increment].
  void decrement(String property, {num value = 1}) =>
      _profileCounter('decrement', property, value);

  /// Properties added to every event from now on, beneath the event's own.
  void setGlobalProperties(Map<String, Object?> properties) {
    _global = {..._global, ...properties};
  }

  /// Turning it off is an opt-out: what was pending is discarded, a request
  /// in flight is aborted, and nothing is recorded until it is turned back
  /// on.
  void setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) {
      _retry?.cancel();
      _attempt = 0;
      _abort();
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

  /// Stops sending and writes the store. Pending events stay stored for the
  /// next launch.
  ///
  /// A request in flight is let finish (it is bounded by [requestTimeout]):
  /// aborting it could leave an event the server already took in the queue,
  /// to be sent again on the next launch.
  Future<void> dispose() async {
    _disposed = true;
    _retry?.cancel();
    await _ready;
    await _sending;
    await persist();
    await _store.close();
    if (_ownsHttp) _http.close();
  }

  /// Writes what is pending to the store now instead of after
  /// [persistDelay]. Call it when the app may be suspended or killed — going
  /// to the background — so the last events are not only in memory.
  Future<void> persist() async {
    await _ready;
    if (_persistTimer?.isActive ?? false) {
      _persistTimer!.cancel();
      _persistTimer = null;
      _persistNow();
    }
    // A save can schedule a follow-up one with what changed meanwhile.
    while (_saving != null) {
      await _saving;
    }
  }

  void _profileCounter(String type, String property, num value) {
    final profileId = _profileId;
    if (profileId == null) return;
    if (value <= 0 || property.isEmpty) {
      _log('$type ignored: the server takes a property and a value > 0');
      return;
    }
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
      // Not a first launch: what is there may be whole, just out of reach
      // (another instance holds it, a file the OS will not open yet). This
      // run keeps its events in memory and leaves the store as it is.
      _storeUsable = false;
      _log('store unavailable, events stay in memory this run: $e');
      // A store held by another instance still tells whose install this is.
      if (e is StoreLockedException) _deviceId = e.deviceId ?? '';
    }
    if (_deviceId.isEmpty) _deviceId = stored?.deviceId ?? newDeviceId();
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
  Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty && _enabled && !_disposed) {
        final body = _queue.first;
        final outcome = await _send(body);
        if (outcome == _Outcome.retry) {
          if (!_disposed && _enabled) _scheduleRetry();
          return;
        }
        _attempt = 0;
        // Not removeAt(0): setEnabled(false) may have cleared the queue
        // while the request was out.
        _queue.remove(body);
        _persist();
      }
    } finally {
      _draining = false;
    }
  }

  Future<_Outcome> _send(Map<String, Object?> body) async {
    final http.AbortableRequest request;
    try {
      // Built outside the network `try`: a body or header this client cannot
      // even put on the wire will not go out on a retry either.
      final abort = _abortInFlight = Completer<void>();
      request =
          http.AbortableRequest('POST', _endpoint, abortTrigger: abort.future)
            ..headers.addAll(_headers)
            ..body = jsonEncode(_prepare(body));
    } on Object catch (e) {
      _log('${body['type']} dropped: it cannot be sent ($e)');
      return _Outcome.dropped;
    }

    // Aborted rather than just abandoned: a request left running after a
    // timeout can still land, and the retry would then count it twice.
    final timeout = Timer(requestTimeout, _abort);
    try {
      // The abort is the timeout; this is the backstop for a client that
      // ignores it (a wrapper that copies the request), so a hung send can
      // never hold the queue for good.
      final response = await Future(
        () async => http.Response.fromStream(await _http.send(request)),
      ).timeout(requestTimeout * 2);
      _learnClock(response);
      return _outcome(body, response);
    } on http.ClientException catch (e) {
      // RequestAbortedException is one of these: a timeout, an opt-out or a
      // dispose. Retrying is right for the first; the others stop the drain.
      _log('${body['type']} not sent (${e.message}); retrying');
      return _Outcome.retry;
    } on TimeoutException {
      _log('${body['type']} timed out; retrying');
      return _Outcome.retry;
    } on IOException catch (e) {
      _log('${body['type']} not sent ($e); retrying');
      return _Outcome.retry;
    } on Object catch (e) {
      // Not the network: retrying would fail the same way forever and hold
      // up every event behind this one.
      _log('${body['type']} dropped: $e');
      return _Outcome.dropped;
    } finally {
      timeout.cancel();
      _abortInFlight = null;
    }
  }

  _Outcome _outcome(Map<String, Object?> body, http.Response response) {
    final status = response.statusCode;
    if (status == 200 || status == 202) return _Outcome.sent;
    if (status == 401 && _refusesTheEvent(response.body)) {
      _log('${body['type']} dropped: ${response.body}');
      return _Outcome.dropped;
    }
    // Busy or broken server, or refused for who is asking rather than what:
    // a wrong or rotated secret, a WAF or a region block answers 401/403 to
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
  }

  /// The 401s OpenPanel answers for the event rather than the client: a
  /// project filter (that IP or that profile), or revenue without a secret.
  /// They are final; sending them later from elsewhere would also defeat the
  /// filter.
  static bool _refusesTheEvent(String body) =>
      body.contains('blocked by project filter') ||
      body.contains('Revenue tracking is not allowed');

  /// Aborts the request in flight, if there is one still running.
  void _abort() {
    final abort = _abortInFlight;
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  void _learnClock(http.Response response) {
    final date = response.headers['date'];
    if (date == null) return;
    try {
      _clockOffset = HttpDate.parse(date).difference(_clock());
    } on Object {
      // A missing or odd `Date` leaves the last offset in place.
    }
  }

  /// The body as it goes on the wire: the install's device id added (an
  /// event recorded before the store loaded did not have it yet), and the
  /// time adjusted for the server.
  Map<String, Object?> _prepare(Map<String, Object?> body) {
    if (body['type'] != 'track') return body;
    final payload = body['payload']! as Map<String, Object?>;
    final properties = {
      '__deviceId': _deviceId,
      ...payload['properties']! as Map<String, Object?>,
    };
    final stamp = sendTimestamp(
      recorded: properties['__timestamp'],
      now: _clock(),
      clockOffset: _clockOffset,
    );
    if (stamp == null) {
      properties.remove('__timestamp');
    } else {
      properties['__timestamp'] = stamp;
    }
    return {
      ...body,
      'payload': {...payload, 'properties': properties},
    };
  }

  late final Map<String, String> _headers = {
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

  /// Writes the current state after [persistDelay], once for every change
  /// made meanwhile.
  void _persist() {
    if (!_storeUsable || _persistTimer != null) return;
    _persistTimer = Timer(persistDelay, () {
      _persistTimer = null;
      _persistNow();
    });
  }

  /// Writes now, coalescing: while one save is out, later changes are
  /// written once by a single follow-up save.
  void _persistNow() {
    if (!_storeUsable) return;
    if (_saving != null) {
      _saveAgain = true;
      return;
    }
    _saving = _save().whenComplete(() {
      _saving = null;
      if (_saveAgain) {
        _saveAgain = false;
        _persistNow();
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

  void _log(String message) {
    try {
      logger?.call('[openpanel] $message');
    } on Object {
      // A logger that throws must not take the client down with it.
    }
  }
}

enum _Outcome { sent, dropped, retry }

final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Whether the server takes [email] as a profile's email.
@internal
bool isValidEmail(String email) => _email.hasMatch(email);

/// Whether the server takes [avatar] as a profile's avatar: an http(s) URL.
@internal
bool isValidAvatar(String avatar) {
  final uri = Uri.tryParse(avatar);
  return uri != null &&
      uri.isAbsolute &&
      (uri.isScheme('http') || uri.isScheme('https'));
}

/// Whether OpenPanel accepts [name] as an event name: 1–80 characters, no
/// line break, and not one of the names it mints itself.
@internal
bool isValidEventName(String name) =>
    name.isNotEmpty &&
    name.length <= 80 &&
    !name.contains('\n') &&
    !name.contains('\r') &&
    name != 'session_start' &&
    name != 'session_end';

/// What goes in `__timestamp` when an event recorded at [recorded] is sent
/// at [now], or null to leave it out.
///
/// Left out for an event under a minute old: the server then stamps it with
/// its own clock, which is right whatever the device's says — many TV boxes
/// have no battery clock and boot in 1970 or hours off. Older events (sent
/// late, from the queue) keep their own time, moved by [clockOffset] (server
/// minus device, learnt from responses) when it is known and more than a
/// couple of minutes. The offset is this run's: an event restored from an
/// earlier run under a different clock error keeps that error. An event the
/// server sees as over 15 minutes old opens no session there: that is
/// OpenPanel's rule for back-dated events.
@visibleForTesting
String? sendTimestamp({
  required Object? recorded,
  required DateTime now,
  Duration? clockOffset,
}) {
  final at = recorded is String ? DateTime.tryParse(recorded) : null;
  // Recorded by a clock that had not been set yet (a TV box that boots in
  // 1970 and syncs later): that time means nothing, arrival is better.
  if (at == null || at.isBefore(_earliestPlausible)) return null;
  final age = now.difference(at);
  // Fresh, or the clock went back since: the arrival time is the better one.
  if (age.isNegative || age < const Duration(minutes: 1)) return null;
  final offset = clockOffset;
  final shifted = offset != null && offset.abs() > const Duration(minutes: 2)
      ? at.add(offset)
      : at;
  return shifted.toUtc().toIso8601String();
}

final _earliestPlausible = DateTime.utc(2024);

/// `/track` under [apiUrl], whether or not it ends in a slash: a bare
/// `resolve('track')` on `https://host/api` would drop the `api`.
@visibleForTesting
Uri trackEndpoint(Uri apiUrl) {
  final path = apiUrl.path.endsWith('/') ? apiUrl.path : '${apiUrl.path}/';
  return apiUrl.replace(path: '${path}track');
}

/// A random (v4) UUID. Its own few lines rather than a dependency.
@visibleForTesting
String newDeviceId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
