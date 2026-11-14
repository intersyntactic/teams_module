import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  setUpAll(setUpKeys);

  late HttpServer server;
  late HttpClient client;
  late List<TeamsEvent> events;
  late List<String> logged;
  late bool keysServed;
  late List<Uint8List> witnessed;
  late bool witnessFails;

  setUp(() async {
    events = [];
    logged = [];
    keysServed = true;
    witnessed = [];
    witnessFails = false;
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
      onEvent: (event) async => events.add(event),
      witness: (body) {
        if (witnessFails) throw const FileSystemException('disk full');
        witnessed.add(body);
      },
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
    // Let the event, handed on after the response, land.
    await pumpEventQueue();
    return (res.statusCode, text, res.headers.contentType);
  }

  test('takes a message: 200 with no body, then the event', () async {
    final (status, body, _) = await post(message());
    expect(status, 200);
    expect(body, isEmpty);
    expect((events.single as TeamsMessage).text, 'Looks right to me');
    expect(logged, ['teams relay: 200 message']);
  });

  test('responds to a card action with the acknowledgement, as JSON', () async {
    final (status, body, type) = await post(cardAction());
    expect(status, 200);
    expect(type?.mimeType, 'application/json');
    expect(jsonDecode(body), {
      'statusCode': 200,
      'type': 'application/vnd.microsoft.activity.message',
      'value': 'Got it',
    });
    expect(events.single, isA<TeamsCardAction>());
  });

  test(
    'responds to a re-sent card action the same, and hands it on once',
    () async {
      final (_, first, _) = await post(cardAction());
      final (status, again, _) = await post(cardAction());
      expect(status, 200);
      expect(again, first);
      expect(events, hasLength(1));
    },
  );

  test('refuses a bad token with a bare 401 and no event', () async {
    final (status, body, _) = await post(message(), token: 'not.a.token');
    expect(status, 401);
    expect(body, isEmpty);
    expect(events, isEmpty);
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
    expect(events, isEmpty);
  });

  /// Sends the head of a POST that promises a 20-byte body, then [trickle]
  /// bytes of it, one every 100ms, and returns the response head the relay
  /// sends and how long after the request's head it came. A raw socket,
  /// since HttpClient reads no response until its whole request is sent.
  Future<(String, Duration)> unfinished(String token, {int trickle = 1}) async {
    final socket = await Socket.connect('127.0.0.1', server.port);
    addTearDown(socket.destroy);
    socket.write(
      'POST ${TeamsRelay.path} HTTP/1.1\r\n'
      'Host: 127.0.0.1\r\n'
      'Authorization: Bearer $token\r\n'
      'Content-Type: application/json\r\n'
      'Content-Length: 20\r\n'
      '\r\n',
    );
    await socket.flush();
    final sent = DateTime.now();
    final head = utf8.decoder.bind(socket).first;
    unawaited(() async {
      try {
        for (var i = 0; i < trickle; i++) {
          socket.add(const [0x20]);
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      } on Object {
        // The relay has responded and closed; the rest has nowhere to go.
      }
    }());
    final response = await head.timeout(const Duration(seconds: 5));
    return (response, DateTime.now().difference(sent));
  }

  test('gives a body one deadline, not one per chunk', () async {
    // A byte every 100ms never leaves a gap as long as the 300ms deadline,
    // so only a deadline on the whole body stops it, and the 408 comes long
    // before the 2s the body would take. The connection goes with it, so
    // the rest of the body has nowhere to land.
    final (response, after) = await unfinished(signedToken(), trickle: 20);
    expect(response, startsWith('HTTP/1.1 408'));
    expect(response.toLowerCase(), contains('connection: close'));
    expect(after, lessThan(const Duration(seconds: 1)));
    expect(logged, ['teams relay: 408 body too slow']);
    expect(events, isEmpty);
  });

  test('refuses a bad token without reading the body', () async {
    // The body never finishes, and nothing reads it: dart:io sends no
    // response while a request's body sits unread, so a relay that left it
    // there would never answer, and one that read it first would wait out
    // the 300ms deadline and send 408.
    final (response, after) = await unfinished('nope');
    expect(response, startsWith('HTTP/1.1 401'));
    expect(response.toLowerCase(), contains('connection: close'));
    expect(after, lessThan(const Duration(milliseconds: 300)));
    expect(logged, ['teams relay: 401 token is not three parts']);
    expect(events, isEmpty);
    expect(witnessed, isEmpty);
  });

  test('says "try again" while it has no keys', () async {
    keysServed = false;
    expect((await post(message())).$1, 503);
    expect(events, isEmpty);
  });

  group('the witness', () {
    test('records the body byte for byte, before responding', () async {
      // Spacing and key order no re-encoding would keep.
      final raw = utf8.encode(
        '{  "text":"Looks right to me" ,${jsonEncode(message()).substring(1)}',
      );
      final (status, _, _) = await post(null, body: raw);
      expect(status, 200);
      expect(witnessed.single, raw);
    });

    test('records nothing a token does not vouch for', () async {
      await post(message(), token: 'nope');
      expect(witnessed, isEmpty);
    });

    test('records a repeat once', () async {
      await post(message());
      await post(message());
      expect(witnessed, hasLength(1));
    });

    test('records nothing it does not hand on', () async {
      await post({...message(), 'type': 'typing'});
      expect(witnessed, isEmpty);
    });

    test('unrecorded is a 500 and handed on to no one', () async {
      witnessFails = true;
      final (status, _, _) = await post(message());
      expect(status, 500);
      expect(events, isEmpty);
      // One line, saying the status sent: a watcher keyed on "500" fires.
      expect(logged, [
        'teams relay: 500 message: witness failed: FileSystemException',
      ]);
    });

    test(
      "Teams' retry of an unrecorded message is taken and recorded",
      () async {
        witnessFails = true;
        await post(message());
        witnessFails = false;
        final (status, _, _) = await post(message());
        expect(status, 200);
        expect(witnessed, hasLength(1));
        expect(events, hasLength(1));
      },
    );
  });
}
