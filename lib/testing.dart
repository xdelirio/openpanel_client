/// Test doubles for apps that use [OpenPanel].
library;

import 'package:openpanel_client/openpanel_client.dart';

/// One call an app made on a [FakeOpenPanel].
typedef RecordedCall = ({
  String method,
  String? name,
  Map<String, Object?> args,
});

/// An [OpenPanel] that sends nothing and records the calls the real client
/// would act on, so a test can assert what the app reported. It follows the
/// same rules: nothing is recorded while disabled, and `increment` /
/// `decrement` before `identify` are ignored.
class FakeOpenPanel implements OpenPanel {
  FakeOpenPanel({this.context = const DeviceContext(os: 'test')});

  final List<RecordedCall> calls = [];

  /// Names of the events tracked, screens included as `screen_view`.
  List<String> get events => [
    for (final call in calls)
      if (call.method == 'track') call.name!,
  ];

  /// The paths passed to [screen], in order.
  List<String> get screens => [
    for (final call in calls)
      if (call.method == 'screen') call.name!,
  ];

  String? _profileId;
  bool _enabled = true;

  @override
  final DeviceContext context;

  @override
  String get clientId => 'fake';

  @override
  String? get clientSecret => null;

  @override
  int get maxQueue => 0;

  @override
  Duration get minBackoff => Duration.zero;

  @override
  Duration get maxBackoff => Duration.zero;

  @override
  Duration get requestTimeout => Duration.zero;

  @override
  void Function(String message)? get logger => null;

  @override
  String get deviceId => 'fake-device';

  @override
  String? get profileId => _profileId;

  @override
  bool get enabled => _enabled;

  @override
  List<Map<String, Object?>> get pending => const [];

  @override
  Future<void> get ready async {}

  @override
  void track(String name, {Map<String, Object?>? properties}) {
    if (!_enabled) return;
    calls.add((method: 'track', name: name, args: {...?properties}));
  }

  @override
  void screen(String path, {Map<String, Object?>? properties}) {
    if (!_enabled) return;
    calls.add((method: 'screen', name: path, args: {...?properties}));
    track('screen_view', properties: properties);
  }

  @override
  void identify(
    String profileId, {
    String? firstName,
    String? lastName,
    String? email,
    String? avatar,
    Map<String, Object?>? properties,
  }) {
    _profileId = profileId;
    if (!_enabled) return;
    calls.add((
      method: 'identify',
      name: profileId,
      args: {
        'firstName': ?firstName,
        'lastName': ?lastName,
        'email': ?email,
        'avatar': ?avatar,
        'properties': ?properties,
      },
    ));
  }

  @override
  void reset() {
    _profileId = null;
    calls.add((method: 'reset', name: null, args: const {}));
  }

  @override
  void increment(String property, {num value = 1}) =>
      _counter('increment', property, value);

  @override
  void decrement(String property, {num value = 1}) =>
      _counter('decrement', property, value);

  void _counter(String method, String property, num value) {
    if (!_enabled || _profileId == null) return;
    calls.add((method: method, name: property, args: {'value': value}));
  }

  /// Recorded even while disabled: the real client keeps them too, and they
  /// apply once it is turned back on.
  @override
  void setGlobalProperties(Map<String, Object?> properties) => calls.add((
    method: 'setGlobalProperties',
    name: null,
    args: {...properties},
  ));

  @override
  void setEnabled(bool enabled) => _enabled = enabled;

  @override
  Future<void> flush() async {}

  @override
  Future<void> dispose() async {}
}
