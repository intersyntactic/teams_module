/// The relay against a real record writer, skipped unless asked for:
///
///     RECORD_LIVE=<dir holding the socket> RECORD_LIVE_SOCKET=j.sock \
///     RECORD_LIVE_EXPECT=recorded|failed|refused|unanswered \
///       dart test test/record_live_test.dart
///
/// It posts one signed message through [TeamsRelay], recorded through
/// [recordEvent], and prints the status Teams would get, the relay's log
/// line and the writer's answer. The socket is named relative to
/// RECORD_LIVE, since macOS caps a socket's path at 104 bytes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final env = Platform.environment;
  final dir = env['RECORD_LIVE'];
  final expectation = env['RECORD_LIVE_EXPECT'];

  test(
    'a signed message, recorded with a real writer',
    () async {
      setUpKeys();
      Directory.current = dir;
      final socket = env['RECORD_LIVE_SOCKET'] ?? 'j.sock';
      final logged = <String>[];
      final answers = <RecordAnswer>[];
      final relay = TeamsRelay(
        spec: const TeamsSourceSpec(appId: appId, tenantAllowlist: {tenant}),
        keys: BotFrameworkKeySource(
          get: (url) async => url.path.endsWith('openidconfiguration')
              ? jsonEncode({'jwks_uri': 'https://login.botframework.com/k'})
              : jwksJson,
          now: () => now,
        ),
        onEvent: (_) async {},
        record: (body) async {
          final a = await recordEvent(socket, source: 'teams', bytes: body);
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
          Recorded(:final entry) => 'recorded $entry',
          RecordFailed(:final why) => 'failed: $why',
          RecordRefused(:final why) => 'refused: $why',
          RecordUnanswered(:final why) => 'unanswered: $why',
        }}',
      );
      stdout.writeln('body   ${base64Encode(body)}');
      final (Type type, int status) = switch (expectation) {
        'recorded' => (Recorded, 200),
        'failed' => (RecordFailed, 200),
        'refused' => (RecordRefused, 500),
        'unanswered' => (RecordUnanswered, 500),
        _ => fail('RECORD_LIVE_EXPECT is $expectation'),
      };
      expect(answer.runtimeType, type);
      expect(res.statusCode, status);
    },
    skip: dir == null
        ? 'set RECORD_LIVE to run against a record writer'
        : false,
  );
}
