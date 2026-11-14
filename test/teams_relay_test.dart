import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(setUpKeys);

  late HttpServer server;
  late HttpClient client;
  late List<TeamsArrival> arrivals;
  late List<String> logged;
  late bool keysServed;

  setUp(() async {
    arrivals = [];
    logged = [];
    keysServed = true;
    final relay = TeamsRelay(
      spec: const TeamsSourceSpec(appId: appId, tenantAllowlist: {tenant}),
      keys: BotFrameworkKeySource(
        get: (url) async => !keysServed
            ? throw HttpException('down', uri: url)
            : url.path.endsWith('openidconfiguration')
            ? jsonEncode({'jwks_uri': 'https://login.botframework.com/k'})
            : jwksJson,
        now: () => now,
      ),
      onArrival: (arrival) async => arrivals.add(arrival),
      now: () => now,
      log: logged.add,
      maxBodyBytes: 64 * 1024,
      bodyTimeout: const Duration(milliseconds: 300),
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(relay.handle);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
  });

  Future<(int, String, ContentType?)> post(
    Object? activity, {
    String path = TeamsRelay.path,
    String method = 'POST',
    String? token,
    List<int>? body,
  }) async {
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    req.headers.set('authorization', 'Bearer ${token ?? signedToken()}');
    req.headers.contentType = ContentType.json;
    req.add(body ?? utf8.encode(jsonEncode(activity)));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    // Let the arrival, handed on after the response, land.
    await pumpEventQueue();
    return (res.statusCode, text, res.headers.contentType);
  }

  test('takes a message: 200 with no body, then the arrival', () async {
    final (status, body, _) = await post(message());
    expect(status, 200);
    expect(body, isEmpty);
    expect(arrivals.single.toJson().string('text'), 'Looks right to me');
  });

  test('answers a card action with the acknowledgement, as JSON', () async {
    final (status, body, type) = await post(cardAction());
    expect(status, 200);
    expect(type?.mimeType, 'application/json');
    expect(jsonDecode(body), {
      'statusCode': 200,
      'type': 'application/vnd.microsoft.activity.message',
      'value': 'Got it',
    });
    expect(arrivals.single.toJson().string('event'), 'teams_card_action');
  });

  test(
    'answers a re-sent card action the same, and hands it on once',
    () async {
      final (_, first, _) = await post(cardAction());
      final (status, again, _) = await post(cardAction());
      expect(status, 200);
      expect(again, first);
      expect(arrivals, hasLength(1));
    },
  );

  test('refuses a bad token with a bare 401 and no arrival', () async {
    final (status, body, _) = await post(message(), token: 'not.a.token');
    expect(status, 401);
    expect(body, isEmpty);
    expect(arrivals, isEmpty);
  });

  test('logs the reason, never the text', () async {
    await post(message(text: 'a sentence that must not be logged'));
    expect(logged, isNotEmpty);
    expect(logged.join('\n'), isNot(contains('must not be logged')));
  });

  test('knows only its one path and its one method', () async {
    expect((await post(message(), path: '/other')).$1, 404);
    expect((await post(null, method: 'GET', body: const [])).$1, 405);
  });

  test('refuses a body over the cap', () async {
    final big = List.filled(64 * 1024 + 1, 0x20);
    expect((await post(null, body: big)).$1, 413);
    expect(arrivals, isEmpty);
  });

  test('gives a body one deadline, not one per chunk', () async {
    // A byte every 100ms never leaves a gap as long as the 300ms deadline,
    // so only a deadline on the whole body stops it.
    final req = await client.post('127.0.0.1', server.port, TeamsRelay.path);
    req.headers.set('authorization', 'Bearer ${signedToken()}');
    req.contentLength = 20;
    final response = req.done;
    unawaited(() async {
      try {
        for (var i = 0; i < 20; i++) {
          req.add(const [0x20]);
          await req.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await req.close();
      } on Exception {
        // The relay has answered and closed; the rest has nowhere to go.
      }
    }());
    final res = await response.timeout(const Duration(seconds: 5));
    expect(res.statusCode, 408);
    expect(arrivals, isEmpty);
  });

  test('says "try again" while it has no keys', () async {
    keysServed = false;
    expect((await post(message())).$1, 503);
    expect(arrivals, isEmpty);
  });
}
