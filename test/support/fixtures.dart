/// What every test signs and sends: two RSA keys, the key set Microsoft
/// would publish for them, tokens signed the way the Bot Connector signs
/// them, and the activities Teams sends.
library;

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

const appId = '00000000-0000-0000-0000-00000000b07a';
final appBot = BotAppId.parse(appId)!;

/// A second bot served from the same endpoint.
const otherAppId = '00000000-0000-0000-0000-0000000b07b2';
final otherBot = BotAppId.parse(otherAppId)!;
const tenant = 'tenant-ada';
const serviceUrl = 'https://smba.trafficmanager.net/amer/';
final now = DateTime.utc(2026, 11, 6, 10);
final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;

late RSAPrivateKey teamsKey; // kid k1, endorsed for msteams
late RSAPrivateKey otherKey; // kid k2, endorsed for another channel only

/// The key set as Microsoft serves it: JSON text.
late String jwksJson;

/// [jwksJson], read.
late BotFrameworkKeys keys;

/// Makes the keys. For a `setUpAll`: 2048-bit generation takes a moment.
void setUpKeys() {
  final k1 = _keyPair(1);
  final k2 = _keyPair(2);
  teamsKey = k1.privateKey;
  otherKey = k2.privateKey;
  jwksJson = jsonEncode({
    'keys': [
      _jwk('k1', k1.publicKey, ['msteams', 'skype']),
      _jwk('k2', k2.publicKey, ['skype']),
      {'kty': 'EC', 'kid': 'ec1', 'crv': 'P-256', 'x': 'AA', 'y': 'AA'},
    ],
  });
  keys = BotFrameworkKeys.parse(JsonObject.decode(jwksJson));
}

Map<String, Object?> message({
  String id = '1730881234567',
  String text = 'Looks right to me',
}) => {
  'type': 'message',
  'id': id,
  'channelId': 'msteams',
  'serviceUrl': serviceUrl,
  'timestamp': '2026-11-06T10:00:00.000Z',
  'from': {
    'id': '29:1ada',
    'aadObjectId': 'ada00000-0000-4000-8000-000000000001',
    'name': 'Ada',
  },
  'recipient': {'id': '28:$appId', 'name': 'Bot'},
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

Map<String, Object?> cardAction() => {
  ...message(id: 'f:9001'),
  'type': 'invoke',
  'name': 'adaptiveCard/action',
  'replyToId': '1730881000000',
  'value': {
    'action': {
      'type': 'Action.Execute',
      'verb': 'approve',
      'data': {'node': 'example-3'},
    },
    'trigger': 'manual',
  },
}..remove('text');

Map<String, Object?> tokenClaims() => {
  'iss': botFrameworkIssuer,
  'aud': appId,
  'serviceurl': serviceUrl,
  'nbf': nowSeconds - 60,
  'exp': nowSeconds + 3600,
};

/// A token signed as the Bot Connector signs one: RS256 over
/// `base64url(header).base64url(claims)`.
String signedToken({
  RSAPrivateKey? key,
  Map<String, Object?> header = const {
    'typ': 'JWT',
    'alg': 'RS256',
    'kid': 'k1',
    'x5t': 'k1',
  },
  Map<String, Object?>? claims,
}) {
  final h = b64(utf8.encode(jsonEncode(header)));
  final c = b64(utf8.encode(jsonEncode(claims ?? tokenClaims())));
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(key ?? teamsKey));
  final signature = signer.generateSignature(utf8.encode('$h.$c'));
  return '$h.$c.${b64(signature.bytes)}';
}

String b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// What the relay records for [activity]: the projection the gate makes of
/// it, encoded as the relay encodes it, under a token the Bot Connector
/// would have sent it with. Throws a [StateError] when the gate refuses it,
/// which a test meaning to record it never wants. Needs [setUpKeys].
List<int> projectedBytes(Map<String, Object?> activity) {
  final a = JsonObject.of(activity);
  final recipient = a.objectOrNull('recipient')?.stringOrNull('id') ?? '';
  final claims = {
    ...tokenClaims(),
    'serviceurl': a.stringOrNull('serviceUrl'),
    'aud': recipient.startsWith('28:') ? recipient.substring(3) : appId,
  };
  return switch (teamsGate(
    spec: TeamsSourceSpec(
      botAppIds: {appBot, otherBot},
      callSettingsDialog: JsonObject.of({'task': 'test dialog'}),
    ),
    keys: keys,
    headers: {'Authorization': 'Bearer ${signedToken(claims: claims)}'},
    body: utf8.encode(jsonEncode(activity)),
    now: now,
  )) {
    TeamsActivityTaken(:final event) => utf8.encode(
      jsonEncode(event.projection().asUncheckedMap()),
    ),
    TeamsActivityRefused(:final refusal) => throw StateError(
      'the gate refused it: ${refusal.reason}',
    ),
  };
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
  'n': b64(_unsigned(k.modulus!)),
  'e': b64(_unsigned(k.exponent!)),
  'endorsements': endorse,
};

Uint8List _unsigned(BigInt n) {
  final hex = n.toRadixString(16);
  final even = hex.length.isOdd ? '0$hex' : hex;
  return Uint8List.fromList([
    for (var i = 0; i < even.length; i += 2)
      int.parse(even.substring(i, i + 2), radix: 16),
  ]);
}
