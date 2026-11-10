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
    final keys = await source().keys();
    expect(fetched, [BotFrameworkKeySource.defaultMetadata, jwksUri]);
    expect(keys!.byId('k1')!.endorsements, contains('msteams'));
  });

  test('uses the set it has until it is twelve hours old', () async {
    final s = source();
    await s.keys();
    clock = now.add(const Duration(hours: 11));
    await s.keys();
    expect(fetched, hasLength(2));
  });

  test('answers with the old set while refreshing it behind', () async {
    final s = source();
    final first = await s.keys();
    clock = now.add(const Duration(hours: 12));
    final during = await s.keys();
    expect(during, same(first));
    await pumpEventQueue();
    expect(fetched, hasLength(4));
    expect(await s.keys(), isNot(same(first)));
  });

  test('keeps the old set when a refresh fails', () async {
    final s = source();
    final first = await s.keys();
    served.remove(jwksUri);
    clock = now.add(const Duration(hours: 13));
    await s.keys();
    await pumpEventQueue();
    expect(await s.keys(), same(first));
    expect(logged.single, contains('refresh failed'));
  });

  test(
    'has nothing before a first fetch succeeds, and waits to retry',
    () async {
      served.remove(jwksUri);
      final s = source();
      expect(await s.keys(), isNull);
      expect(await s.keys(), isNull);
      expect(fetched, hasLength(2), reason: 'no second try inside a minute');
      served[jwksUri] = jwksJson;
      clock = now.add(const Duration(minutes: 1));
      expect(await s.keys(), isNotNull);
    },
  );

  test('refuses a key set served over plain http', () async {
    served[BotFrameworkKeySource.defaultMetadata] = jsonEncode({
      'jwks_uri': 'http://login.botframework.com/v1/.well-known/keys',
    });
    expect(await source().keys(), isNull);
    expect(logged.single, contains('not https'));
  });

  test('fetches once for requests that arrive together', () async {
    final s = source();
    await Future.wait([s.keys(), s.keys(), s.keys()]);
    expect(fetched, hasLength(2));
  });
}
