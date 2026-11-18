# openpanel_client

An [OpenPanel](https://openpanel.dev) client for Flutter apps on every
platform (Android, Android TV, iOS, macOS, Windows, Linux). It sends what the
app reports — events, screens, profiles — to a self-hosted or cloud
instance; what to report is the app's.

- **Core** (`package:openpanel_client/openpanel_client.dart`, pure Dart) —
  `OpenPanel`: every call is stamped with its time, queued, stored and sent
  in the background, in order, one `POST /track` each (the server has no
  batch endpoint). Lost connections, timeouts (aborted; delivery is
  at-least-once), 5xx, 408, 429, 403 and a 401 about the client are retried with
  backoff; a 401 about the event (a project filter) and other 4xx drop the
  event. Nothing throws or waits on the network.
- **Flutter** (`package:openpanel_client/flutter.dart`) —
  `detectDeviceContext()` (OS, version, model, brand, form factor, app
  release), `OpenPanelObserver` (a `screen_view` per named route on the
  navigator it observes) and
  `OpenPanelLifecycle` (flushes on resume and on hide).
- **Testing** (`package:openpanel_client/testing.dart`) — `FakeOpenPanel`,
  which records the calls instead of sending them.

## Why not a browser-style client

OpenPanel identifies a browser from its IP and `User-Agent`. An app has
neither a browser UA nor a stable IP, so every event states it itself:

| Property | What it is |
|---|---|
| `__deviceId` | A UUID made once per install and kept in the store, so the device does not change with the network. |
| `__os`, `__osVersion`, `__model`, `__brand`, `__device` | The device. On servers before v3.0 the `User-Agent` decides instead, which is why the client sends one the server's parser reads (`Mac OS X 15.1` on macOS, ASCII only). |
| `__version`, `__buildNumber` | The app release the event happened in. |
| `__timestamp` | Only on events over a minute old (sent from the queue), corrected by the server's clock (`Date` header). Fresh events take the server's arrival time, so a device with a wrong clock does not matter. |
| `__path` | The last screen reported with `screen()`. |

### Server requirements and limits

- **OpenPanel v2.3.0 or later.** Before it, an event carrying `__deviceId`
  is stored with an empty session: no sessions, durations or bounce. A
  `/track` response with `"sessionId":""` is the sign.
- An event the server sees as **over 15 minutes old** opens no session —
  OpenPanel's rule for back-dated events. A backlog sent after a long time
  offline counts as events, not as visits.
- The server drops `null` and empty-string values and flattens nested maps
  (`a.b`, at most 50 keys each). Event names are 1–80 characters, with no
  line breaks; the client drops the ones the server would refuse.
- `increment`/`decrement` take a value > 0 and need the profile to exist:
  right after a new user's first event the server may answer 404 and the
  change is lost.
- One store per app: a second instance of a desktop app finds it locked
  and keeps its events in memory for that run.

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

// Navigator 1.0: MaterialApp(navigatorObservers: [OpenPanelObserver(panel)])
//
// go_router: an observer only sees the root navigator (not the ones of a
// ShellRoute / StatefulShellRoute) and pages built by `pageBuilder` have no
// name unless given one. Listen to the router instead:
final delegate = router.routerDelegate;
delegate.addListener(() {
  final path = delegate.currentConfiguration.fullPath; // `/content/:id`
  if (path.isNotEmpty) panel.screen(path);
});
```

`setEnabled(false)` is an opt-out: pending events are discarded, a request
in flight is aborted, and nothing is recorded until it is turned back on.
The app keeps the preference.

After an outage the queue waits for its backoff (up to 5 minutes) or a
lifecycle change; an app that knows when the network is back can call
`flush()` then.

Property values must be JSON (strings, numbers, booleans, null, lists and
maps of those); an event with anything else is dropped at the call and
logged through `logger`.

## Trying it against an instance

```bash
dart run example/send.dart https://openpanel.example.com/api <clientId> [secret]
```

It sends an `identify`, a `screen_view` and an event; they should show on
the dashboard with the device and version, and with a session on servers
v2.3.0 or later.
