/// The keys Microsoft signs Teams deliveries with, read from the JSON Web Key
/// Set that the Bot Connector's OpenID document points at
/// (`https://login.botframework.com/v1/.well-known/keys`).
///
/// They are PUBLIC keys. That is the difference from Slack, whose gate has to
/// hold a signing secret it shares with Slack: a Teams gate holds nothing a
/// leak would hurt, only the bot's app id, which is printed in the app's own
/// manifest. Fetching and refreshing the set (Microsoft asks for at least once
/// a day) is the caller's, so the gate that reads it stays pure.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';
import 'package:pointycastle/asymmetric/api.dart';

/// One signing key, and the channels it is endorsed for.
final class BotFrameworkKey {
  const BotFrameworkKey(this.key, this.endorsements);

  final RSAPublicKey key;

  /// Channel ids (`msteams`, ...) this key may sign for. A token for a Teams
  /// activity signed by a key not endorsed for `msteams` is refused: the
  /// endorsement is what makes the activity's `channelId` trustworthy.
  final Set<String> endorsements;
}

/// The key set, by key id.
final class BotFrameworkKeys {
  BotFrameworkKeys._(this._byId);

  final Map<String, BotFrameworkKey> _byId;

  /// The key a token's header names, or null when the set has none by that
  /// id: a key rotated out, or a token from somewhere else.
  BotFrameworkKey? byId(String kid) => _byId[kid];

  /// The RSA signing keys in [jwks], a decoded `{"keys": [...]}` document.
  ///
  /// A key of another type or use is passed over rather than refused, so a
  /// set Microsoft extends with, say, an EC key still yields its RSA keys. A
  /// malformed RSA key is a [JsonFieldException]: half a key set is a fault
  /// to see, not one to route around.
  static BotFrameworkKeys parse(JsonObject jwks) => BotFrameworkKeys._({
    for (final k in jwks.objects('keys'))
      if (k.stringOrNull('kty') == 'RSA' &&
          (k.stringOrNull('use') ?? 'sig') == 'sig')
        k.string('kid'): BotFrameworkKey(
          RSAPublicKey(_unsigned(k, 'n'), _unsigned(k, 'e')),
          (k.stringsOrNull('endorsements') ?? const []).toSet(),
        ),
  });
}

/// The base64url field [name] of [k] as an unsigned big-endian integer, the
/// way a JWK writes an RSA modulus and exponent.
BigInt _unsigned(JsonObject k, String name) {
  final Uint8List bytes;
  try {
    bytes = base64Url.decode(base64Url.normalize(k.string(name)));
  } on FormatException {
    throw JsonFieldException(name, 'base64url');
  }
  if (bytes.isEmpty) throw JsonFieldException(name, 'a non-empty integer');
  return bytes.fold(BigInt.zero, (n, b) => (n << 8) | BigInt.from(b));
}
