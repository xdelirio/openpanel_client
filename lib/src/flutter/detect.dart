import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:openpanel_client/src/device_context.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Reads the [DeviceContext] of the device the app runs on.
///
/// [kind] wins over what is detected: only the app knows some of it (a
/// tablet layout, a TV build). Detection treats an Android with the leanback
/// feature as a TV and an iPad as a tablet; every other phone OS is
/// `mobile`, and every desktop OS `desktop`.
///
/// Never throws: whatever a platform will not tell is left out.
Future<DeviceContext> detectDeviceContext({DeviceKind? kind}) async {
  PackageInfo? app;
  try {
    app = await PackageInfo.fromPlatform();
  } on Object {
    app = null;
  }
  final fields = await _deviceFields();
  return DeviceContext(
    os: fields.os,
    osVersion: fields.osVersion,
    model: fields.model,
    brand: fields.brand,
    kind: kind ?? fields.kind,
    appName: app?.appName,
    appVersion: app?.version,
    buildNumber: app?.buildNumber,
  );
}

typedef _Fields = ({
  String os,
  String? osVersion,
  String? model,
  String? brand,
  DeviceKind? kind,
});

Future<_Fields> _deviceFields() async {
  final plugin = DeviceInfoPlugin();
  try {
    if (kIsWeb) {
      final web = await plugin.webBrowserInfo;
      return (
        os: 'Web',
        osVersion: null,
        model: web.browserName.name,
        brand: null,
        kind: null,
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final a = await plugin.androidInfo;
        return (
          os: 'Android',
          osVersion: a.version.release,
          model: a.model,
          brand: brandName(a.manufacturer),
          kind: a.systemFeatures.contains('android.software.leanback')
              ? DeviceKind.smarttv
              : DeviceKind.mobile,
        );
      case TargetPlatform.iOS:
        final i = await plugin.iosInfo;
        return (
          os: 'iOS',
          osVersion: i.systemVersion,
          model: i.modelName,
          brand: 'Apple',
          kind: i.model.toLowerCase().contains('ipad')
              ? DeviceKind.tablet
              : DeviceKind.mobile,
        );
      case TargetPlatform.macOS:
        final m = await plugin.macOsInfo;
        return (
          os: 'macOS',
          osVersion: '${m.majorVersion}.${m.minorVersion}.${m.patchVersion}',
          model: m.modelName,
          brand: 'Apple',
          kind: DeviceKind.desktop,
        );
      case TargetPlatform.windows:
        final w = await plugin.windowsInfo;
        return (
          os: 'Windows',
          osVersion: w.displayVersion.isNotEmpty
              ? w.displayVersion
              : '${w.majorVersion}.${w.minorVersion}.${w.buildNumber}',
          model: windowsProductName(w.productName, w.buildNumber),
          brand: null,
          kind: DeviceKind.desktop,
        );
      case TargetPlatform.linux:
        final l = await plugin.linuxInfo;
        return (
          os: 'Linux',
          osVersion: l.versionId,
          model: l.prettyName,
          brand: null,
          kind: DeviceKind.desktop,
        );
      case TargetPlatform.fuchsia:
        break;
    }
  } on Object {
    // Fall through to the bare platform name.
  }
  return (
    os: defaultTargetPlatform.name,
    osVersion: null,
    model: null,
    brand: null,
    kind: null,
  );
}

/// [manufacturer] as a brand is written: Android reports some in lower case
/// (`samsung`, `xiaomi`), which the dashboard would list apart from the same
/// brand parsed from a browser.
@visibleForTesting
String brandName(String manufacturer) {
  final trimmed = manufacturer.trim();
  if (trimmed.isEmpty || trimmed != trimmed.toLowerCase()) return trimmed;
  return trimmed[0].toUpperCase() + trimmed.substring(1);
}

/// The registry keeps calling Windows 11 "Windows 10" in its product name;
/// the build number is what tells them apart (22000 and up is 11).
@visibleForTesting
String windowsProductName(String productName, int build) =>
    build >= 22000 && productName.startsWith('Windows 10')
    ? productName.replaceFirst('Windows 10', 'Windows 11')
    : productName;
