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

  /// A `name/version (os version; model)` agent, in printable ASCII.
  ///
  /// HTTP headers take nothing else: an app named `Películas+` or a model
  /// with Chinese characters makes the request fail before it leaves, and
  /// every event behind it with it. Accents are folded (`Peliculas+`), the
  /// rest becomes `_`.
  ///
  /// macOS is spelled `Mac OS X 15.1`, which is how the server's
  /// user-agent parser recognises it; `macOS 15.1` reads as a server.
  String get userAgent {
    final system = os == 'macOS' ? 'Mac OS X' : os;
    final details = [
      [system, ?osVersion].join(' '),
      ?model,
    ].join('; ');
    return asciiHeaderValue(
      '${appName ?? 'app'}/${appVersion ?? '0'} ($details)',
    );
  }

  static bool _present(String? value) => value != null && value.isNotEmpty;
}

const _folds = {
  'á': 'a',
  'à': 'a',
  'ä': 'a',
  'â': 'a',
  'ã': 'a',
  'å': 'a',
  'é': 'e',
  'è': 'e',
  'ë': 'e',
  'ê': 'e',
  'í': 'i',
  'ì': 'i',
  'ï': 'i',
  'î': 'i',
  'ó': 'o',
  'ò': 'o',
  'ö': 'o',
  'ô': 'o',
  'õ': 'o',
  'ú': 'u',
  'ù': 'u',
  'ü': 'u',
  'û': 'u',
  'ñ': 'n',
  'ç': 'c',
  'Á': 'A',
  'À': 'A',
  'Ä': 'A',
  'Â': 'A',
  'Ã': 'A',
  'Å': 'A',
  'É': 'E',
  'È': 'E',
  'Ë': 'E',
  'Ê': 'E',
  'Í': 'I',
  'Ì': 'I',
  'Ï': 'I',
  'Î': 'I',
  'Ó': 'O',
  'Ò': 'O',
  'Ö': 'O',
  'Ô': 'O',
  'Õ': 'O',
  'Ú': 'U',
  'Ù': 'U',
  'Ü': 'U',
  'Û': 'U',
  'Ñ': 'N',
  'Ç': 'C',
};

/// [value] reduced to what an HTTP header may carry: printable ASCII, with
/// common Latin accents folded and anything else replaced by `_`.
@visibleForTesting
String asciiHeaderValue(String value) {
  final out = StringBuffer();
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    if (rune >= 0x20 && rune <= 0x7e) {
      out.write(char);
    } else {
      out.write(_folds[char] ?? '_');
    }
  }
  return out.toString();
}
