# openpanel_client

An [OpenPanel](https://openpanel.dev) client for Flutter apps on every
platform (Android, Android TV, iOS, macOS, Windows, Linux). It sends what the
app reports — events, screens, profiles — to a self-hosted or cloud
instance; what to report is the app's.

- **Core** (`package:openpanel_client/openpanel_client.dart`, pure Dart) —
  `OpenPanel`: every call is stamped with its time, queued, stored and sent
  in the background, in order, one `POST /track` each (the server has no
  batch endpoint). Server errors and lost connections are retried with
  backoff; refused events (4xx) are dropped. Nothing throws or waits on the
  network.
- **Flutter** (`package:openpanel_client/flutter.dart`) —
  `detectDeviceContext()` (OS, version, model, brand, form factor, app
  release), `OpenPanelObserver` (a `screen_view` per named route) and
  `OpenPanelLifecycle` (flushes on resume and on hide).
- **Testing** (`package:openpanel_client/testing.dart`) — `FakeOpenPanel`,
  which records the calls instead of sending them.

## Why not a browser-style client

OpenPanel identifies a browser from its IP and `User-Agent`. An app has
neither a browser UA nor a stable IP, so every event states it itself:

| Property | What it is |
|---|---|
| `__deviceId` | A UUID made once per install and kept in the store: sessions do not split when the phone changes network. |
| `__os`, `__osVersion`, `__model`, `__brand`, `__device` | The device. Without them a plain `app/1.0` agent is filed as a server. |
| `__version`, `__buildNumber` | The app release the event happened in. |
| `__timestamp` | When it happened, so an event sent after a day offline lands on the day it happened. |
| `__path` | The last screen reported with `screen()`. |

## Usage

```dart
final panel = OpenPanel(
  apiUrl: Uri.parse('https://openpanel.example.com/api'),
  clientId: '…',
  context: await detectDeviceContext(),
  store: FileQueueStore(File('${supportDir.path}/openpanel.json')),
);
final lifecycle = OpenPanelLifecycle(panel);

panel.identify(user.uuid, properties: {'plan': user.plan});
panel.track('play_started', properties: {'contentId': id, 'quality': '1080p'});
panel.reset(); // sign-out or account switch: the install's device id stays

MaterialApp.router(/* … */);
// go_router: GoRouter(observers: [OpenPanelObserver(panel)], …)
```

`setEnabled(false)` is an opt-out: pending events are discarded and nothing
is recorded until it is turned back on. The app keeps the preference.

Property values must be JSON (strings, numbers, booleans, null, lists and
maps of those); an event with anything else is dropped at the call and
logged through `logger`.

## Trying it against an instance

```bash
dart run example/send.dart https://openpanel.example.com/api <clientId> [secret]
```

It sends an `identify`, a `screen_view` and an event; they should show on
the dashboard with the device, version and a session.
