import 'dart:convert';

import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

final serviceUrl = Uri.parse('https://smba.trafficmanager.net/amer/');
const conversation = 'a:1personal;messageid=17';

void main() {
  late List<
    ({String method, Uri url, Map<String, String> headers, String body})
  >
  calls;
  late DateTime clock;
  late int tokenStatus;

  setUp(() {
    calls = [];
    clock = DateTime.utc(2026, 11, 7, 3);
    tokenStatus = 200;
  });

  BotConnector connector() => BotConnector(
    appId: 'app-1',
    secret: 's3cret',
    tenantId: 'tenant-test',
    now: () => clock,
    http: (method, url, headers, body) async {
      calls.add((method: method, url: url, headers: headers, body: body));
      if (url.host == 'login.microsoftonline.com') {
        return (
          status: tokenStatus,
          body: tokenStatus == 200
              ? jsonEncode({
                  'token_type': 'Bearer',
                  'expires_in': 3600,
                  'access_token': 'tok-${calls.length}',
                })
              : '{"error":"invalid_client"}',
        );
      }
      if (url.path.contains('broken')) return (status: 403, body: '{}');
      return (status: 200, body: jsonEncode({'id': 'new-1'}));
    },
  );

  test('gets a token from its own tenant, for the Connector', () async {
    await connector().send(serviceUrl, conversation, {'type': 'message'});
    final token = calls.first;
    expect(token.method, 'POST');
    expect(
      token.url.toString(),
      'https://login.microsoftonline.com/tenant-test/oauth2/v2.0/token',
    );
    expect(Uri.splitQueryString(token.body), {
      'grant_type': 'client_credentials',
      'client_id': 'app-1',
      'client_secret': 's3cret',
      'scope': 'https://api.botframework.com/.default',
    });
  });

  test('sends, with the token, to the conversation, encoded', () async {
    final id = await connector().send(serviceUrl, conversation, {
      'type': 'message',
      'text': 'hi',
    });
    expect(id, 'new-1');
    final send = calls.last;
    expect(send.method, 'POST');
    expect(
      send.url.toString(),
      'https://smba.trafficmanager.net/amer/v3/conversations/'
      'a%3A1personal%3Bmessageid%3D17/activities',
    );
    expect(send.headers['authorization'], 'Bearer tok-1');
    expect(jsonDecode(send.body), {'type': 'message', 'text': 'hi'});
  });

  test('replies to an activity, and edits one by its id', () async {
    final c = connector();
    await c.reply(serviceUrl, conversation, 'f:9', {'type': 'message'});
    expect(calls.last.url.path, endsWith('/activities/f%3A9'));
    expect(calls.last.method, 'POST');
    await c.update(serviceUrl, conversation, 'm1', {'type': 'message'});
    expect(calls.last.method, 'PUT');
    expect(calls.last.url.path, endsWith('/activities/m1'));
    expect(jsonDecode(calls.last.body), {'type': 'message', 'id': 'm1'});
  });

  test('joins a service URL with or without its trailing slash', () async {
    await connector().send(
      Uri.parse('https://smba.trafficmanager.net/amer'),
      'c',
      {},
    );
    expect(
      calls.last.url.toString(),
      'https://smba.trafficmanager.net/amer/v3/conversations/c/activities',
    );
  });

  test('keeps a token until five minutes before it expires', () async {
    final c = connector();
    await c.send(serviceUrl, 'c', {});
    clock = clock.add(const Duration(minutes: 54));
    await c.send(serviceUrl, 'c', {});
    expect(
      calls.where((x) => x.url.host == 'login.microsoftonline.com'),
      hasLength(1),
    );
    clock = clock.add(const Duration(minutes: 1));
    await c.send(serviceUrl, 'c', {});
    expect(
      calls.where((x) => x.url.host == 'login.microsoftonline.com'),
      hasLength(2),
    );
  });

  test('never sends its token to a service URL that is not https', () async {
    await expectLater(
      connector().send(
        Uri.parse('http://smba.trafficmanager.net/amer/'),
        'c',
        {},
      ),
      throwsArgumentError,
    );
    expect(calls.where((x) => x.url.scheme == 'http'), isEmpty);
  });

  test('says which call failed, and with what', () async {
    await expectLater(
      connector().send(serviceUrl, 'broken', {}),
      throwsA(
        isA<BotConnectorException>()
            .having((e) => e.what, 'what', 'send')
            .having((e) => e.status, 'status', 403),
      ),
    );
    tokenStatus = 401;
    await expectLater(
      connector().send(serviceUrl, 'c', {}),
      throwsA(
        isA<BotConnectorException>().having((e) => e.what, 'what', 'token'),
      ),
    );
  });

  test('refuses to be made without its three settings', () {
    expect(
      () => BotConnector(appId: 'a', secret: '', tenantId: 't'),
      throwsArgumentError,
    );
  });
}
