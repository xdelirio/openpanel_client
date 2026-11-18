import 'package:flutter/widgets.dart';
import 'package:openpanel_client/src/client.dart';

/// Sends what is pending when the app comes back to the foreground — the
/// usual moment a phone has its network back — and, when it goes to the
/// background, writes the queue at once and sends what it can: the OS may
/// suspend or kill it before the store's delayed write runs.
///
/// Dispose it with the client.
class OpenPanelLifecycle {
  OpenPanelLifecycle(OpenPanel client)
    : _listener = AppLifecycleListener(
        onResume: client.flush,
        onHide: () {
          client.persist();
          client.flush();
        },
      );

  final AppLifecycleListener _listener;

  void dispose() => _listener.dispose();
}
