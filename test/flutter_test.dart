import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openpanel_client/flutter.dart';
import 'package:openpanel_client/openpanel_client.dart';
import 'package:openpanel_client/testing.dart';

void main() {
  test('DeviceContext states only what it knows', () {
    const context = DeviceContext(os: 'Linux', kind: DeviceKind.desktop);
    expect(context.toProperties(), {'__os': 'Linux', '__device': 'desktop'});
    expect(context.userAgent, 'app/0 (Linux)');
  });

  testWidgets('the observer reports named pages, not popups', (tester) async {
    final panel = FakeOpenPanel();
    final navigator = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [OpenPanelObserver(panel)],
        initialRoute: '/',
        routes: {
          '/': (_) => const Text('home'),
          '/detail': (_) => const Text('detail'),
        },
      ),
    );

    navigator.currentState!.pushNamed('/detail');
    await tester.pumpAndSettle();
    showDialog<void>(
      context: navigator.currentContext!,
      builder: (_) => const Text('dialog'),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.pop(); // the dialog: /detail never left
    await tester.pumpAndSettle();
    navigator.currentState!.pop(); // back to home
    await tester.pumpAndSettle();
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('unnamed')),
    );
    await tester.pumpAndSettle();

    expect(panel.screens, ['/', '/detail', '/']);
  });

  testWidgets('nameOf picks what a route is reported as', (tester) async {
    final panel = FakeOpenPanel();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [
          OpenPanelObserver(
            panel,
            nameOf: (route) => route.settings.name == '/' ? 'Home' : null,
          ),
        ],
        home: const Text('home'),
      ),
    );

    expect(panel.screens, ['Home']);
    expect(panel.events, ['screen_view']);
  });

  test('the fake ignores what the real client ignores', () {
    final panel = FakeOpenPanel()
      ..increment('plays')
      ..identify('u')
      ..increment('plays')
      ..setEnabled(false)
      ..track('hidden')
      ..identify('v');
    expect(panel.calls.map((c) => c.method), ['identify', 'increment']);
    expect(panel.profileId, 'v');
  });
}
