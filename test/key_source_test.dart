import 'dart:convert';
import 'dart:io';

import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

final jwksUri = Uri.parse('https://login.botframework.com/v1/.well-known/keys');

void main() {
  setUpAll(setUpKeys);

  late DateTime clock;
  late List<Uri> fetched;
  late Map<Uri, String> served;
  late List<String> logged;

  setUp(() {
    clock = now;
    fetched = [];
    logged = [];
    served = {
      BotFrameworkKeySource.defaultMetadata: jsonEncode({
        'issuer': botFrameworkIssuer,
        'jwks_uri': jwksUri.toString(),
      }),
      jwksUri: jwksJson,
    };
  });

  BotFrameworkKeySource source() => BotFrameworkKeySource(
    get: (url) async {
      fetched.add(url);
      return served[url] ?? (throw HttpException('GET $url: 503', uri: url));
    },
    now: () => clock,
    log: logged.add,
  );

  test('fetches the OpenID document, then the key set it names', () async {
    final keys = await source().refresh();
    expect(fetched, [BotFrameworkKeySource.defaultMetadata, jwksUri]);
    expect(keys!.byId('k1')!.endorsements, contains('msteams'));
  });

  test('has none before a fetch, and starts one without waiting', () async {
    final s = source();
    expect(s.current(), isNull);
    await pumpEventQueue();
    expect(fetched, hasLength(2));
    expect(s.current(), isNotNull);
  });

  test('uses the set it has until it is twelve hours old', () async {
    final s = source();
    await s.refresh();
    clock = now.add(const Duration(hours: 11));
    s.current();
    await pumpEventQueue();
    expect(fetched, hasLength(2));
  });

  test('answers with the old set while refreshing it behind', () async {
    final s = source();
    final first = await s.refresh();
    clock = now.add(const Duration(hours: 12));
    expect(s.current(), same(first));
    await pumpEventQueue();
    expect(fetched, hasLength(4));
    expect(s.current(), isNot(same(first)));
  });

  test('keeps the old set when a refresh fails', () async {
    final s = source();
    final first = await s.refresh();
    served.remove(jwksUri);
    clock = now.add(const Duration(hours: 13));
    s.current();
    await pumpEventQueue();
    expect(s.current(), same(first));
    expect(logged.single, contains('refresh failed'));
  });

  test(
    'has nothing before a first fetch succeeds, and waits to retry',
    () async {
      served.remove(jwksUri);
      final s = source();
      expect(await s.refresh(), isNull);
      expect(s.current(), isNull);
      await pumpEventQueue();
      expect(fetched, hasLength(2), reason: 'no second try inside a minute');
      served[jwksUri] = jwksJson;
      clock = now.add(const Duration(minutes: 1));
      s.current();
      await pumpEventQueue();
      expect(s.current(), isNotNull);
    },
  );

  test('refuses a key set served over plain http', () async {
    served[BotFrameworkKeySource.defaultMetadata] = jsonEncode({
      'jwks_uri': 'http://login.botframework.com/v1/.well-known/keys',
    });
    expect(await source().refresh(), isNull);
    expect(logged.single, contains('not https'));
  });

  test('fetches once for requests that arrive together', () async {
    final s = source();
    s.current();
    s.current();
    await s.refresh();
    expect(fetched, hasLength(2));
  });
}
