/// The relay against a real airlock service, skipped unless asked for:
///
///     AIRLOCK_LIVE=<dir holding the socket> AIRLOCK_LIVE_SOCKET=a.sock \
///     AIRLOCK_LIVE_EXPECT=witnessed|record-failed|not-witnessed \
///       dart test test/airlock_live_test.dart
///
/// It posts one signed message through [TeamsRelay], witnessed through
/// [witnessThroughAirlock], and prints the status Teams would get, the
/// relay's log line and the airlock's answer. The socket is named relative
/// to AIRLOCK_LIVE, since macOS caps a socket's path at 104 bytes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final env = Platform.environment;
  final dir = env['AIRLOCK_LIVE'];
  final expectation = env['AIRLOCK_LIVE_EXPECT'];

  test('a signed message, witnessed through a real airlock', () async {
    setUpKeys();
    Directory.current = dir;
    final socket = env['AIRLOCK_LIVE_SOCKET'] ?? 'a.sock';
    final logged = <String>[];
    final answers = <AirlockAnswer>[];
    final relay = TeamsRelay(
      spec: const TeamsSourceSpec(appId: appId, tenantAllowlist: {tenant}),
      keys: BotFrameworkKeySource(
        get: (url) async => url.path.endsWith('openidconfiguration')
            ? jsonEncode({'jwks_uri': 'https://login.botframework.com/k'})
            : jwksJson,
        now: () => now,
      ),
      onEvent: (_) async {},
      witness: (body) async {
        final a = await witnessThroughAirlock(
          socket,
          source: 'teams',
          bytes: body,
        );
        answers.add(a);
        return a;
      },
      now: () => now,
      log: logged.add,
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(relay.handle);
    final client = HttpClient();
    final body = utf8.encode(
      jsonEncode(message(id: '${DateTime.now().millisecondsSinceEpoch}')),
    );
    final req = await client.post('127.0.0.1', server.port, TeamsRelay.path);
    req.headers.set('authorization', 'Bearer ${signedToken()}');
    req.add(body);
    final res = await req.close();
    await res.drain<void>();
    client.close(force: true);
    await server.close(force: true);

    final answer = answers.single;
    stdout.writeln('status ${res.statusCode}');
    stdout.writeln('log    ${logged.single}');
    stdout.writeln(
      'answer ${switch (answer) {
        AirlockWitnessed(:final entry) => 'witnessed $entry',
        AirlockRecordFailed(:final error) => 'record failed: $error',
        AirlockNotWitnessed(:final error) => 'not witnessed: $error',
      }}',
    );
    stdout.writeln('body   ${base64Encode(body)}');
    switch (expectation) {
      case 'witnessed':
        expect(answer, isA<AirlockWitnessed>());
        expect(res.statusCode, 200);
      case 'record-failed':
        expect(answer, isA<AirlockRecordFailed>());
        expect(res.statusCode, 200);
        expect(logged.single, contains('RECORD FAILED'));
      case 'not-witnessed':
        expect(answer, isA<AirlockNotWitnessed>());
        expect(res.statusCode, 500);
      default:
        fail('AIRLOCK_LIVE_EXPECT is $expectation');
    }
  }, skip: dir == null ? 'set AIRLOCK_LIVE to run against an airlock' : false);
}
