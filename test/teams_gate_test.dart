import 'dart:convert';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/rsa_key_generator.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/signers/rsa_signer.dart';
import 'package:test/test.dart';

const appId = '00000000-0000-0000-0000-00000000b07a';
const tenant = 'tenant-peter';
const serviceUrl = 'https://smba.trafficmanager.net/amer/';
final now = DateTime.utc(2026, 11, 6, 10);
final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;

late RSAPrivateKey teamsKey; // kid k1, endorsed for msteams
late RSAPrivateKey otherKey; // kid k2, endorsed for another channel only
late BotFrameworkKeys keys;

void main() {
  setUpAll(() {
    final k1 = _keyPair(1);
    final k2 = _keyPair(2);
    teamsKey = k1.privateKey;
    otherKey = k2.privateKey;
    // Through JSON and back, as the set arrives from Microsoft.
    keys = BotFrameworkKeys.parse(
      JsonObject.decode(
        jsonEncode({
          'keys': [
            _jwk('k1', k1.publicKey, ['msteams', 'skype']),
            _jwk('k2', k2.publicKey, ['skype']),
            {'kty': 'EC', 'kid': 'ec1', 'crv': 'P-256', 'x': 'AA', 'y': 'AA'},
          ],
        }),
      ),
    );
  });

  group('takes', () {
    test('a message in a one-to-one chat, with its text', () {
      final d = _gate(_message());
      expect(d.outcome, TeamsGateOutcome.trigger);
      expect(d.status, 200);
      expect(d.invokeResponse, isNull);
      expect(d.seenKey, jsonEncode(['a:1personal', '1730881234567']));
      expect(d.doorbell!.asUncheckedMap(), {
        'event': 'teams_message',
        'tenant': tenant,
        'conversation': 'a:1personal',
        'conversation_type': 'personal',
        'activity': '1730881234567',
        'service_url': serviceUrl,
        'timestamp': '2026-11-06T10:00:00.000Z',
        'from': '29:1peter',
        'from_aad_object_id': 'oid-peter',
        'recipient': '28:$appId',
        'text': 'Looks right to me',
      });
    });

    test('a card action, answered with the acknowledgement', () {
      final d = _gate(_cardAction());
      expect(d.outcome, TeamsGateOutcome.trigger);
      expect(d.invokeResponse!.asUncheckedMap(), {
        'statusCode': 200,
        'type': 'application/vnd.microsoft.activity.message',
        'value': 'Got it',
      });
      final bell = d.doorbell!;
      expect(bell.string('event'), 'teams_card_action');
      expect(bell.string('name'), 'adaptiveCard/action');
      expect(bell.string('reply_to'), '1730881000000');
      expect(bell.object('value').object('action').string('verb'), 'approve');
    });

    test('an audience given as a list', () {
      final t = _token(
        claims: {
          ..._claims(),
          'aud': ['someone', appId],
        },
      );
      expect(_gate(_message(), token: t).outcome, TeamsGateOutcome.trigger);
    });

    test('the claim spelled serviceUrl, as the docs spell it', () {
      final claims = _claims()
        ..remove('serviceurl')
        ..['serviceUrl'] = serviceUrl;
      final t = _token(claims: claims);
      expect(_gate(_message(), token: t).outcome, TeamsGateOutcome.trigger);
    });

    test('a key named by x5t alone', () {
      final t = _token(header: {'typ': 'JWT', 'alg': 'RS256', 'x5t': 'k1'});
      expect(_gate(_message(), token: t).outcome, TeamsGateOutcome.trigger);
    });

    test('a token inside the clock skew at either end', () {
      final late_ = _token(claims: {..._claims(), 'exp': nowSeconds - 240});
      final early = _token(claims: {..._claims(), 'nbf': nowSeconds + 240});
      expect(_gate(_message(), token: late_).outcome, TeamsGateOutcome.trigger);
      expect(_gate(_message(), token: early).outcome, TeamsGateOutcome.trigger);
    });

    test('an install, which carries what messaging first needs', () {
      final d = _gate(
        {..._message(), 'type': 'installationUpdate', 'action': 'add'}
          ..remove('text'),
      );
      expect(d.outcome, TeamsGateOutcome.trigger);
      expect(d.doorbell!.string('event'), 'teams_installation_update');
      expect(d.doorbell!.string('action'), 'add');
      expect(d.doorbell!.string('service_url'), serviceUrl);
    });

    test('a quoted reply, with the entities that say what it quotes', () {
      // The quotedReply entity's fields here are illustrative, not
      // Microsoft's schema: the gate passes entities on unread, which is
      // what this proves.
      final entities = [
        {
          'type': 'mention',
          'mentioned': {'id': '28:$appId', 'name': 'Hart'},
          'text': '<at>Hart</at>',
        },
        {'type': 'quotedReply', 'messageId': '1730881000000'},
      ];
      final d = _gate({
        ..._message(
          text: '<quoted messageId="1730881000000"/> <at>Hart</at> not quite',
        ),
        'entities': entities,
      });
      expect(d.outcome, TeamsGateOutcome.trigger);
      expect(jsonEncode(d.doorbell!.raw('entities')), jsonEncode(entities));
      expect(d.doorbell!.string('text'), startsWith('<quoted messageId='));
    });

    test('a conversation update, with who joined', () {
      final d = _gate(
        {
          ..._message(),
          'type': 'conversationUpdate',
          'membersAdded': [
            {'id': '28:$appId'},
          ],
        }..remove('text'),
      );
      expect(d.doorbell!.string('event'), 'teams_conversation_update');
      expect(d.doorbell!.strings('members_added'), ['28:$appId']);
    });
  });

  group('ignores', () {
    test('a quiet activity type, but still marks it seen', () {
      final d = _gate({..._message(), 'type': 'typing'}..remove('text'));
      expect(d.outcome, TeamsGateOutcome.ignore);
      expect(d.status, 200);
      expect(d.doorbell, isNull);
      expect(d.seenKey, isNotNull);
    });

    test('an invoke it was not built for, with no answer to give', () {
      final d = _gate({..._cardAction(), 'name': 'composeExtension/query'});
      expect(d.outcome, TeamsGateOutcome.ignore);
      expect(d.invokeResponse, isNull);
    });

    test('an activity already seen', () {
      final seen = <String>{};
      final first = _gate(_message(), hasSeen: seen.contains);
      seen.add(first.seenKey!);
      final again = _gate(_message(), hasSeen: seen.contains);
      expect(again.outcome, TeamsGateOutcome.ignore);
      expect(again.doorbell, isNull);
    });

    test('a card action re-sent, still answered as the first was', () {
      final seen = {_gate(_cardAction()).seenKey!};
      final again = _gate(_cardAction(), hasSeen: seen.contains);
      expect(again.outcome, TeamsGateOutcome.ignore);
      expect(again.invokeResponse!.string('value'), 'Got it');
    });

    test('the same activity id in another conversation is not a repeat', () {
      final seen = {_gate(_message()).seenKey!};
      final elsewhere = {
        ..._message(),
        'conversation': {'id': '19:group@thread.v2', 'tenantId': tenant},
      };
      expect(
        _gate(elsewhere, hasSeen: seen.contains).outcome,
        TeamsGateOutcome.trigger,
      );
    });
  });

  group('refuses', () {
    void refused(TeamsGateDecision d, int status, Matcher reason) {
      expect(d.outcome, TeamsGateOutcome.reject);
      expect(d.status, status);
      expect(d.reason, reason);
      expect(d.doorbell, isNull);
      expect(d.invokeResponse, isNull);
      // An unauthenticated request never reaches the seen set.
      expect(d.seenKey, isNull);
    }

    test('when no app id is configured', () {
      refused(
        _gate(_message(), spec: const TeamsSourceSpec(appId: '')),
        401,
        contains('app id'),
      );
    });

    test('a body over the cap', () {
      final d = teamsGate(
        spec: const TeamsSourceSpec(appId: appId),
        keys: keys,
        headers: {'Authorization': 'Bearer ${_token()}'},
        body: utf8.encode(jsonEncode(_message())),
        now: now,
        maxBodyBytes: 10,
      );
      refused(d, 401, contains('over cap'));
    });

    test('a request with no bearer token', () {
      refused(_gate(_message(), headers: {}), 401, contains('bearer'));
      refused(
        _gate(_message(), headers: {'Authorization': 'Basic abc'}),
        401,
        contains('bearer'),
      );
    });

    test('a token that is not three parts', () {
      refused(_gate(_message(), token: 'a.b'), 401, contains('three parts'));
    });

    test('an unsigned token that says alg none', () {
      String seg(Object o) => _b64(utf8.encode(jsonEncode(o)));
      final t = '${seg({'alg': 'none', 'kid': 'k1'})}.${seg(_claims())}.';
      refused(_gate(_message(), token: t), 401, contains('alg none'));
    });

    test('a token that names an HMAC algorithm', () {
      final t = _token(header: {'alg': 'HS256', 'kid': 'k1'});
      refused(_gate(_message(), token: t), 401, contains('HS256'));
    });

    test('a token from a key not in the set', () {
      final t = _token(header: {'alg': 'RS256', 'kid': 'rotated-out'});
      refused(_gate(_message(), token: t), 401, contains('not in the key set'));
    });

    test('claims changed after signing', () {
      final [h, _, s] = _token().split('.');
      final forged = _b64(
        utf8.encode(jsonEncode({..._claims(), 'aud': 'another-bot'})),
      );
      refused(
        _gate(_message(), token: '$h.$forged.$s'),
        401,
        contains('bad signature'),
      );
    });

    test('a signature the wrong length for its key', () {
      final [h, c, _] = _token().split('.');
      refused(
        _gate(_message(), token: '$h.$c.${_b64([1, 2, 3])}'),
        401,
        contains('wrong length'),
      );
    });

    test('a token from another issuer', () {
      final t = _token(
        claims: {..._claims(), 'iss': 'https://sts.windows.net/x/'},
      );
      refused(_gate(_message(), token: t), 401, contains('issuer'));
    });

    test('a token for another bot', () {
      final t = _token(claims: {..._claims(), 'aud': 'another-bot'});
      refused(_gate(_message(), token: t), 401, contains('audience'));
    });

    test('a token past its expiry and the skew', () {
      final t = _token(claims: {..._claims(), 'exp': nowSeconds - 301});
      refused(_gate(_message(), token: t), 401, contains('expired'));
    });

    test('a token not yet valid, beyond the skew', () {
      final t = _token(claims: {..._claims(), 'nbf': nowSeconds + 301});
      refused(_gate(_message(), token: t), 401, contains('not valid'));
    });

    test('a token with no expiry', () {
      final t = _token(claims: _claims()..remove('exp'));
      refused(_gate(_message(), token: t), 401, contains('no expiry'));
    });

    test('a token with no serviceurl claim', () {
      final t = _token(claims: _claims()..remove('serviceurl'));
      refused(_gate(_message(), token: t), 401, contains('no serviceurl'));
    });

    test('a serviceurl claim that is not the activity\'s', () {
      final t = _token(
        claims: {..._claims(), 'serviceurl': 'https://elsewhere.example/'},
      );
      refused(_gate(_message(), token: t), 401, contains('does not match'));
    });

    test('an activity from another channel', () {
      refused(
        _gate({..._message(), 'channelId': 'slack'}),
        403,
        contains('not msteams'),
      );
    });

    test('a Teams activity signed by a key not endorsed for Teams', () {
      final t = _token(key: otherKey, header: {'alg': 'RS256', 'kid': 'k2'});
      refused(_gate(_message(), token: t), 403, contains('not endorsed'));
    });

    test('a tenant not on the allowlist, or no tenant at all', () {
      final other = {
        ..._message(),
        'channelData': {
          'tenant': {'id': 'someone-else'},
        },
      };
      refused(_gate(other), 403, contains('someone-else'));
      final none = {
        ..._message(),
        'conversation': {'id': 'a:1personal'},
      }..remove('channelData');
      refused(_gate(none), 403, contains('not allowed'));
    });

    test('a body that is not a JSON object', () {
      refused(
        _gate(_message(), body: utf8.encode('[1]')),
        400,
        contains('JSON'),
      );
    });

    test('an activity missing what every activity has', () {
      refused(
        _gate(_message()..remove('conversation')),
        400,
        contains('conversation'),
      );
    });
  });

  test('cannot tell a body from the one the token came with: '
      'the documented limit, pinned', () {
    // The token is valid; the body is not the one Microsoft sent with it.
    // Nothing the gate can check catches that, because no documented check
    // of the token covers the body (see the library comment, point 2).
    final d = _gate(_message(text: 'words Peter never typed'));
    expect(d.outcome, TeamsGateOutcome.trigger);
    expect(d.doorbell!.string('text'), 'words Peter never typed');
  });

  group('the key set', () {
    test('passes over a key of another type', () {
      expect(keys.byId('ec1'), isNull);
      expect(keys.byId('k1')!.endorsements, {'msteams', 'skype'});
    });

    test('refuses a malformed RSA key', () {
      expect(
        () => BotFrameworkKeys.parse(
          JsonObject.decode(
            jsonEncode({
              'keys': [
                {'kty': 'RSA', 'kid': 'bad', 'n': '***', 'e': 'AQAB'},
              ],
            }),
          ),
        ),
        throwsA(isA<JsonFieldException>()),
      );
    });
  });
}

TeamsGateDecision _gate(
  Map<String, Object?> activity, {
  String? token,
  Map<String, String>? headers,
  TeamsSourceSpec spec = const TeamsSourceSpec(
    appId: appId,
    tenantAllowlist: {tenant},
  ),
  bool Function(String)? hasSeen,
  List<int>? body,
}) => teamsGate(
  spec: spec,
  keys: keys,
  headers: headers ?? {'Authorization': 'Bearer ${token ?? _token()}'},
  body: body ?? utf8.encode(jsonEncode(activity)),
  now: now,
  hasSeen: hasSeen,
);

Map<String, Object?> _message({
  String id = '1730881234567',
  String text = 'Looks right to me',
}) => {
  'type': 'message',
  'id': id,
  'channelId': 'msteams',
  'serviceUrl': serviceUrl,
  'timestamp': '2026-11-06T10:00:00.000Z',
  'from': {'id': '29:1peter', 'aadObjectId': 'oid-peter', 'name': 'Peter'},
  'recipient': {'id': '28:$appId', 'name': 'Hart'},
  'conversation': {
    'id': 'a:1personal',
    'conversationType': 'personal',
    'tenantId': tenant,
  },
  'channelData': {
    'tenant': {'id': tenant},
  },
  'text': text,
};

Map<String, Object?> _cardAction() => {
  ..._message(id: 'f:9001'),
  'type': 'invoke',
  'name': 'adaptiveCard/action',
  'replyToId': '1730881000000',
  'value': {
    'action': {
      'type': 'Action.Execute',
      'verb': 'approve',
      'data': {'node': 'rung-3'},
    },
    'trigger': 'manual',
  },
}..remove('text');

Map<String, Object?> _claims() => {
  'iss': botFrameworkIssuer,
  'aud': appId,
  'serviceurl': serviceUrl,
  'nbf': nowSeconds - 60,
  'exp': nowSeconds + 3600,
};

/// A token signed as the Bot Connector signs one: RS256 over
/// `base64url(header).base64url(claims)`.
String _token({
  RSAPrivateKey? key,
  Map<String, Object?> header = const {
    'typ': 'JWT',
    'alg': 'RS256',
    'kid': 'k1',
    'x5t': 'k1',
  },
  Map<String, Object?>? claims,
}) {
  final h = _b64(utf8.encode(jsonEncode(header)));
  final c = _b64(utf8.encode(jsonEncode(claims ?? _claims())));
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(key ?? teamsKey));
  final signature = signer.generateSignature(utf8.encode('$h.$c'));
  return '$h.$c.${_b64(signature.bytes)}';
}

/// A 2048-bit key, seeded so every run makes the same one.
AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _keyPair(int seed) {
  final random = FortunaRandom()
    ..seed(KeyParameter(Uint8List.fromList(List.generate(32, (i) => seed))));
  final generator = RSAKeyGenerator()
    ..init(
      ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
        random,
      ),
    );
  return generator.generateKeyPair();
}

Map<String, Object?> _jwk(String kid, RSAPublicKey k, List<String> endorse) => {
  'kty': 'RSA',
  'use': 'sig',
  'kid': kid,
  'n': _b64(_unsigned(k.modulus!)),
  'e': _b64(_unsigned(k.exponent!)),
  'endorsements': endorse,
};

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List _unsigned(BigInt n) {
  final hex = n.toRadixString(16);
  final even = hex.length.isOdd ? '0$hex' : hex;
  return Uint8List.fromList([
    for (var i = 0; i < even.length; i += 2)
      int.parse(even.substring(i, i + 2), radix: 16),
  ]);
}
