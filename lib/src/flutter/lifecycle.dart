import 'package:flutter/widgets.dart';
import 'package:openpanel_client/src/client.dart';

/// Sends what is pending when the app comes back to the foreground — the
/// usual moment a phone has its network back — and when it goes to the
/// background, the last chance before the OS may suspend it.
///
/// Dispose it with the client.
class OpenPanelLifecycle {
  OpenPanelLifecycle(OpenPanel client)
    : _listener = AppLifecycleListener(
        onResume: client.flush,
        onHide: client.flush,
      );

  final AppLifecycleListener _listener;

  void dispose() => _listener.dispose();
}
