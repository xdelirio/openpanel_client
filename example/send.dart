// Sends a few events to a real OpenPanel instance, to check them on its
// dashboard:
//
//   dart run example/send.dart <apiUrl> <clientId> [clientSecret]
//
// e.g. dart run example/send.dart https://op.example.com/api abc123
// ignore_for_file: avoid_print -- a command-line example.

import 'dart:io';

import 'package:openpanel_client/openpanel_client.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: send.dart <apiUrl> <clientId> [clientSecret]');
    exit(64);
  }
  final panel =
      OpenPanel(
          apiUrl: Uri.parse(args[0]),
          clientId: args[1],
          clientSecret: args.length > 2 ? args[2] : null,
          context: const DeviceContext(
            os: 'Android',
            osVersion: '15',
            model: 'Pixel 9',
            brand: 'Google',
            kind: DeviceKind.mobile,
            appName: 'openpanel_client-example',
            appVersion: '0.1.0',
            buildNumber: '1',
          ),
          logger: print,
        )
        ..identify(
          'example-user',
          firstName: 'Example',
          properties: {'plan': 'test'},
        )
        ..screen('/home')
        ..track('example_event', properties: {'source': 'example/send.dart'});

  await panel.flush();
  await panel.dispose();
  print(panel.pending.isEmpty ? 'sent' : '${panel.pending.length} not sent');
}
