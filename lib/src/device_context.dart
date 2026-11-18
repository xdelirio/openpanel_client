import 'package:meta/meta.dart';

/// The form factor OpenPanel files a device under. The names are the ones
/// its user-agent parser produces, so the dashboard groups an app's devices
/// with the web's.
enum DeviceKind { mobile, tablet, desktop, smarttv }

/// What the app runs on, sent with every event.
///
/// OpenPanel works this out from the `User-Agent` of a browser. An app's
/// client has no browser UA, and a plain `name/version` one is classed as a
/// server — no device, no OS, no sessions — unless the event states the
/// device itself. These are those statements (`__os`, `__model`, …).
@immutable
class DeviceContext {
  const DeviceContext({
    required this.os,
    this.osVersion,
    this.model,
    this.brand,
    this.kind,
    this.appName,
    this.appVersion,
    this.buildNumber,
  });

  /// `Android`, `iOS`, `macOS`, `Windows`, `Linux`…
  final String os;
  final String? osVersion;
  final String? model;
  final String? brand;
  final DeviceKind? kind;

  /// Only used for the `User-Agent`; the dashboard does not show it.
  final String? appName;
  final String? appVersion;
  final String? buildNumber;

  /// The reserved properties OpenPanel reads the device and release from.
  Map<String, String> toProperties() => {
    '__os': os,
    if (_present(osVersion)) '__osVersion': osVersion!,
    if (_present(model)) '__model': model!,
    if (_present(brand)) '__brand': brand!,
    if (kind != null) '__device': kind!.name,
    if (_present(appVersion)) '__version': appVersion!,
    if (_present(buildNumber)) '__buildNumber': buildNumber!,
  };

  /// A `name/version (os version; model)` agent. The server only uses it to
  /// fingerprint the device when the event carries no `__deviceId`, which
  /// this client always sends; it is set so its logs say who called.
  String get userAgent {
    final details = [
      [os, ?osVersion].join(' '),
      ?model,
    ].join('; ');
    return '${appName ?? 'app'}/${appVersion ?? '0'} ($details)';
  }

  static bool _present(String? value) => value != null && value.isNotEmpty;
}
