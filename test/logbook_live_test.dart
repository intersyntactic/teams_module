/// The relay against a real logbook writer, skipped unless asked for:
///
///     LOGBOOK_LIVE=/abs/path/to/j.sock \
///     LOGBOOK_LIVE_EXPECT=recorded|unrecorded \
///       dart test test/logbook_live_test.dart
///
/// It posts one signed message through is_relay's `RelayServer` with
/// [TeamsDeliveryCheck], and prints the status Teams would get and the
/// relay's log line, which says what the writer answered. The path must be
/// absolute, and macOS caps a socket's path at 104 bytes, so put the writer's
/// socket somewhere short, such as /tmp/j.sock.
library;

import 'dart:convert';
import 'dart:io';

import 'package:is_relay/is_relay.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final env = Platform.environment;
  final socket = env['LOGBOOK_LIVE'];
  final expectation = env['LOGBOOK_LIVE_EXPECT'];

  test(
    'a signed message, recorded with a real writer',
    () async {
      setUpKeys();
      final logged = <String>[];
      final keys = BotFrameworkKeySource(
        get: (url) async => url.path.endsWith('openidconfiguration')
            ? jsonEncode({'jwks_uri': 'https://login.botframework.com/k'})
            : jwksJson,
        now: () => now,
      );
      await keys.refresh();
      final relay = RelayServer.projecting(
        check: TeamsDeliveryCheck(
          spec: TeamsSourceSpec(botAppIds: {appBot}, tenantAllowlist: {tenant}),
          keys: keys,
        ),
        logbook: LogbookSocket.parse(socket!)!,
        path: RelayPath.parse('/api/messages')!,
        budget: const Duration(seconds: 12),
        rate: WriteRateBound(perMinute: 600, burst: 60),
        now: () => now,
        log: logged.add,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serving = relay.serve(server);
      final client = HttpClient();
      final activity = message(id: '${DateTime.now().millisecondsSinceEpoch}');
      final body = utf8.encode(jsonEncode(activity));
      final req = await client.post('127.0.0.1', server.port, '/api/messages');
      req.headers.set('authorization', 'Bearer ${signedToken()}');
      req.add(body);
      final res = await req.close();
      await res.drain<void>();
      client.close(force: true);
      await server.close(force: true);
      await serving;

      stdout.writeln('status ${res.statusCode}');
      stdout.writeln('log    ${logged.single}');
      // What the entry should hold: the projection, not the body sent.
      stdout.writeln('entry  ${base64Encode(projectedBytes(activity))}');
      expect(res.statusCode, switch (expectation) {
        'recorded' => 200,
        'unrecorded' => 503,
        _ => fail('LOGBOOK_LIVE_EXPECT is $expectation'),
      });
    },
    skip: socket == null
        ? "set LOGBOOK_LIVE to a writer's socket to run against it"
        : false,
  );
}
