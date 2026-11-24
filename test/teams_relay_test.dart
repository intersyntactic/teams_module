import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';
import 'package:is_content_id/is_content_id.dart' show ObjectId;
import 'package:is_docking_station_api/is_docking_station_api.dart';
import 'package:is_relay/is_relay.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// How the fake logbook answers a write.
enum _Answer { ok, failed }

/// A logbook writer on a Unix socket, speaking its wire protocol: the
/// request `<kind>\n<previous>\n<body>` to the end of the stream, then one
/// line back.
final class _FakeLogbook {
  _FakeLogbook._(this._server, this.socket, this._dir);

  static Future<_FakeLogbook> start() async {
    final dir = await Directory.systemTemp.createTemp('teams');
    final path = '${dir.path}/w.sock';
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final logbook = _FakeLogbook._(server, LogbookSocket.parse(path)!, dir);
    server.listen(logbook._serve);
    return logbook;
  }

  final ServerSocket _server;
  final Directory _dir;
  final LogbookSocket socket;

  _Answer answer = _Answer.ok;

  /// Each entry the writer said `ok` to: its kind and body.
  final recorded = <(String, Uint8List)>[];

  Future<void> _serve(Socket s) async {
    final b = BytesBuilder();
    await s.forEach(b.add);
    final request = b.takeBytes();
    final first = request.indexOf(0x0a);
    final second = request.indexOf(0x0a, first + 1);
    switch (answer) {
      case _Answer.ok:
        recorded.add((
          utf8.decode(request.sublist(0, first)),
          Uint8List.sublistView(request, second + 1),
        ));
        // The writer names the request's hash; the client holds it to that.
        s.write('ok ${ObjectId.of(request).hex}\n');
      case _Answer.failed:
        s.write('failed disk\n');
    }
    await s.close();
  }

  Future<void> stop() async {
    await _server.close();
    await _dir.delete(recursive: true);
  }
}

void main() {
  setUpAll(setUpKeys);

  late _FakeLogbook logbook;
  late HttpServer server;
  late HttpClient client;
  late List<String> logged;
  late BotFrameworkKeySource keys;

  final dialog = teamsDialog(
    title: 'Call settings',
    card: JsonObject.of({'type': 'AdaptiveCard', 'version': '1.5'}),
  );

  setUp(() async {
    logged = [];
    logbook = await _FakeLogbook.start();
    keys = BotFrameworkKeySource(
      get: (url) async => url.path.endsWith('openidconfiguration')
          ? jsonEncode({'jwks_uri': 'https://login.botframework.com/k'})
          : jwksJson,
      now: () => now,
    );
    await keys.refresh();
    final relay = RelayServer(
      check: TeamsDeliveryCheck(
        spec: TeamsSourceSpec(
          botAppIds: {appBot},
          tenantAllowlist: {tenant},
          invokeResponses: {'composeExtension/fetchTask': dialog},
        ),
        keys: keys,
      ),
      logbook: logbook.socket,
      path: RelayPath.parse('/api/messages')!,
      budget: const Duration(seconds: 2),
      rate: WriteRateBound(perMinute: 600, burst: 60),
      now: () => now,
      log: logged.add,
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(relay.serve(server));
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    await logbook.stop();
  });

  Future<(int, String)> post(Object? activity, {String? token}) async {
    final req = await client.post('127.0.0.1', server.port, '/api/messages');
    req.headers.set('authorization', 'Bearer ${token ?? signedToken()}');
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode(activity)));
    final res = await req.close();
    return (res.statusCode, await res.transform(utf8.decoder).join());
  }

  test('records a message as a teams-event, byte for byte, then 200', () async {
    final bytes = utf8.encode(jsonEncode(message()));
    final (status, body) = await post(message());
    expect(status, 200);
    expect(body, isEmpty);
    final (kind, entry) = encodeRelayedEvent(
      teamsEventSource,
      at: now.toUtc(),
      bytes: bytes,
    );
    final (recordedKind, recordedEntry) = logbook.recorded.single;
    expect(recordedKind, kind.name);
    expect(recordedEntry, entry);
  });

  test('answers a card press with the acknowledgement once recorded', () async {
    final (status, body) = await post(cardAction());
    expect(status, 200);
    expect(jsonDecode(body), {
      'statusCode': 200,
      'type': 'application/vnd.microsoft.activity.message',
      'value': 'Got it',
    });
    expect(logbook.recorded, hasLength(1));
  });

  test('records a quiet activity too: typing, a dialog opened', () async {
    expect(
      (await post({...message(), 'type': 'typing'}..remove('text'))).$1,
      200,
    );
    final fetch = {...cardAction(), 'name': 'composeExtension/fetchTask'};
    final (status, body) = await post(fetch);
    expect(status, 200);
    expect(jsonDecode(body), dialog.asUncheckedMap());
    expect(logbook.recorded, hasLength(2));
  });

  test('records a resend again: the docking station decides it once', () async {
    await post(message());
    await post(message());
    expect(logbook.recorded, hasLength(2));
  });

  test('with the logbook failing, answers 503 and no dialog', () async {
    logbook.answer = _Answer.failed;
    final fetch = {...cardAction(), 'name': 'composeExtension/fetchTask'};
    final (status, body) = await post(fetch);
    expect(status, 503);
    expect(body, isEmpty);
  });

  test('refuses a bad token with 401, recording nothing', () async {
    expect((await post(message(), token: 'not.a.token')).$1, 401);
    expect(logbook.recorded, isEmpty);
    expect(logged.single, contains('401'));
  });

  test('refuses an activity from a tenant not allowed with 403', () async {
    final elsewhere = {
      ...message(),
      'conversation': {'id': 'a:1personal', 'tenantId': 'other'},
      'channelData': {
        'tenant': {'id': 'other'},
      },
    };
    expect((await post(elsewhere)).$1, 403);
    expect(logbook.recorded, isEmpty);
  });

  test('says "try again" while it has no keys', () async {
    final noKeys = BotFrameworkKeySource(
      get: (url) async => throw HttpException('down', uri: url),
      now: () => now,
    );
    final relay = RelayServer(
      check: TeamsDeliveryCheck(
        spec: TeamsSourceSpec(botAppIds: {appBot}, tenantAllowlist: {tenant}),
        keys: noKeys,
      ),
      logbook: logbook.socket,
      path: RelayPath.parse('/api/messages')!,
      budget: const Duration(seconds: 2),
      rate: WriteRateBound(perMinute: 600, burst: 60),
      log: logged.add,
    );
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => other.close(force: true));
    unawaited(relay.serve(other));
    final req = await client.post('127.0.0.1', other.port, '/api/messages');
    req.headers.set('authorization', 'Bearer ${signedToken()}');
    req.add(utf8.encode(jsonEncode(message())));
    final res = await req.close();
    await res.drain<void>();
    expect(res.statusCode, 503);
    expect(logbook.recorded, isEmpty);
  });
}
