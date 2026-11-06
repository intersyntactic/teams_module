/// Decides whether an inbound Teams delivery is authentic, and what the shim
/// should do with it.
///
/// A sibling of the Slack module's `slack_gate.dart`, and pure like it: the
/// key set and the seen set are the caller's, so every case is testable
/// without a clock, a socket, or Microsoft. Four things differ from Slack,
/// each forced by Teams (https://github.com/intersyntactic/teams_module/issues/1):
///
/// 1. AUTHENTICATION is a JWT that Microsoft signs with a private key and the
///    gate checks against Microsoft's published public keys. The gate holds
///    no secret, only the bot's app id, which is the token's audience.
///
/// 2. THE TOKEN VOUCHES FOR THE SENDER, NOT THE BODY. Slack's and GitHub's
///    HMACs are computed over the body; no documented check of this token
///    touches it. The `serviceurl` claim matched against the activity is the
///    only thing tying the two together. So whoever runs the shim is trusted
///    with content, in any design.
///
/// 3. THE DOORBELL CARRIES CONTENT (Nick, 2026-11-06). A card submission
///    exists nowhere but this request, and nothing can read a one-to-one
///    chat back short of permission over every chat in the tenant, so a
///    doorbell that only said "something happened" would lose both. Text
///    and submitted values ride in the doorbell.
///
/// 4. REPLAYS ARE KEYED BY ACTIVITY, NOT SIGNATURE. Because the doorbell
///    carries content, the receiver acts on it, which is the condition
///    `relay.dart` names for needing a seen set. Slack's gate keys its seen
///    set by signature digest; that cannot work here, because the Bot
///    Connector reuses one token across many deliveries until it expires.
///    The key is the conversation id with the activity id. Teams also
///    re-sends anything not answered within 15 seconds, so duplicates are
///    ordinary traffic, not only attacks.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/signers/rsa_signer.dart';

import 'bot_framework_keys.dart';

/// The issuer of every token the Bot Connector sends to a bot.
const botFrameworkIssuer = 'https://api.botframework.com';

/// What the caller should do.
enum TeamsGateOutcome {
  /// Hand [TeamsGateDecision.doorbell] on; answer 200, with
  /// [TeamsGateDecision.invokeResponse] as the body when there is one.
  trigger,

  /// Authentic but not for waking anyone: a quiet activity type, or one
  /// already seen. Answer 200, still with [TeamsGateDecision.invokeResponse]
  /// when there is one, since a re-sent card action wants the same answer
  /// the first one got.
  ignore,

  /// Refused. Answer [TeamsGateDecision.status] and never say why in the
  /// body; the log may.
  reject,
}

final class TeamsGateDecision {
  const TeamsGateDecision._(
    this.outcome,
    this.reason, {
    this.status = 200,
    this.doorbell,
    this.invokeResponse,
    this.seenKey,
  });

  const TeamsGateDecision._reject(int status, String reason)
    : this._(TeamsGateOutcome.reject, reason, status: status);

  final TeamsGateOutcome outcome;

  /// Operator-facing, logged. A rejection reason in a response body is a
  /// hint to whoever is guessing.
  final String reason;

  /// The HTTP status to answer: 200 unless refused. 401 for a request that
  /// is not from the Bot Connector, 403 for an authentic one this bot won't
  /// take (a key not endorsed for Teams, a tenant not allowed), 400 for an
  /// authentic activity that isn't one.
  final int status;

  /// What the receiver is told, present iff [outcome] is
  /// [TeamsGateOutcome.trigger]. Absent fields are left out:
  /// ```
  /// {
  ///   "event": "teams_message" | "teams_card_action"
  ///          | "teams_conversation_update" | "teams_installation_update"
  ///          | "teams_message_update" | "teams_message_delete" | ...,
  ///   "tenant": "...",               // the Entra tenant id
  ///   "conversation": "...",         // the conversation id
  ///   "conversation_type": "personal" | "groupChat" | "channel",
  ///   "activity": "...",             // the activity id
  ///   "reply_to": "...",             // a card action: the card's own id
  ///   "service_url": "https://smba.trafficmanager.net/...",
  ///   "timestamp": "...",
  ///   "from": "29:...",              // the channel's id for the sender
  ///   "from_aad_object_id": "...",   // the sender's Entra object id
  ///   "recipient": "28:...",         // the bot's id in this conversation
  ///   "text": "...",                 // a message, or an edit
  ///   "value": {...},                // a card action: what was submitted
  ///   "name": "adaptiveCard/action", // an invoke
  ///   "event_type": "editMessage",   // channelData.eventType, when given
  ///   "action": "add",               // an installation update
  ///   "members_added": ["..."],
  ///   "members_removed": ["..."]
  /// }
  /// ```
  final JsonObject? doorbell;

  /// The body to answer an invoke with. Teams waits for it before showing
  /// the person anything, and the agent is too far away to answer in time,
  /// so the gate answers with a fixed acknowledgement and the agent edits
  /// the card afterwards. Present for a card action, seen or not.
  final JsonObject? invokeResponse;

  /// What the caller adds to its seen set: the conversation id and activity
  /// id, as a JSON list so no id can run into the other. Present on every
  /// outcome except a rejection, so an unauthenticated request never fills
  /// the set.
  final String? seenKey;

  bool get shouldWake => outcome == TeamsGateOutcome.trigger;
}

final class TeamsSourceSpec {
  const TeamsSourceSpec({
    required this.appId,
    this.tenantAllowlist = const {},
    this.wakeActivityTypes = const {
      'message',
      'conversationUpdate',
      'installationUpdate',
      'messageUpdate',
      'messageDelete',
    },
    this.wakeInvokes = const {'adaptiveCard/action'},
    this.acknowledgement = 'Got it',
  });

  /// The bot's Microsoft app id: the audience every token must name. Empty
  /// is a configuration error, and the gate refuses rather than opens.
  final String appId;

  /// Tenants whose activities are taken. Empty means "any tenant whose
  /// activity is correctly signed", which is only ever right in tests.
  final Set<String> tenantAllowlist;

  /// Activity types that wake the receiver. `conversationUpdate` and
  /// `installationUpdate` are among them because they carry what the agent
  /// needs to message a conversation first: its service URL, id and tenant.
  final Set<String> wakeActivityTypes;

  /// Invoke names that wake the receiver. Each is answered with
  /// [acknowledgement].
  final Set<String> wakeInvokes;

  /// What Teams shows after a card action, before the agent edits the card.
  final String acknowledgement;
}

TeamsGateDecision teamsGate({
  required TeamsSourceSpec spec,
  required BotFrameworkKeys keys,
  required Map<String, String> headers,
  required List<int> body,
  required DateTime now,
  bool Function(String seenKey)? hasSeen,
  Duration maxClockSkew = const Duration(minutes: 5),
  int maxBodyBytes = 1024 * 1024,
}) {
  // FAIL CLOSED on a missing app id, as the Slack gate does on a missing
  // secret: a deploy that forgot an env var becomes a refuser.
  if (spec.appId.isEmpty) {
    return const TeamsGateDecision._reject(401, 'app id not configured');
  }
  if (body.length > maxBodyBytes) {
    return TeamsGateDecision._reject(401, 'body ${body.length}b over cap');
  }

  final auth = {
    for (final e in headers.entries) e.key.toLowerCase(): e.value,
  }['authorization'];
  if (auth == null || !auth.startsWith('Bearer ')) {
    return const TeamsGateDecision._reject(401, 'no bearer token');
  }
  final JsonObject claims;
  final BotFrameworkKey key;
  switch (_verify(
    auth.substring('Bearer '.length).trim(),
    keys: keys,
    appId: spec.appId,
    now: now,
    skew: maxClockSkew,
  )) {
    case _Refused(:final reason):
      return TeamsGateDecision._reject(401, reason);
    case _Verified(claims: final c, key: final k):
      claims = c;
      key = k;
  }

  final JsonObject activity;
  try {
    activity = JsonObject.decode(utf8.decode(body));
  } on FormatException {
    return const TeamsGateDecision._reject(400, 'body is not a JSON object');
  }
  try {
    return _decide(spec, activity, claims, key, hasSeen);
  } on FormatException catch (e) {
    return TeamsGateDecision._reject(400, 'activity: ${e.message}');
  }
}

TeamsGateDecision _decide(
  TeamsSourceSpec spec,
  JsonObject a,
  JsonObject claims,
  BotFrameworkKey key,
  bool Function(String seenKey)? hasSeen,
) {
  // The endorsement is what makes channelId trustworthy: a key Microsoft
  // has not endorsed for Teams may not sign a Teams activity.
  final channel = a.string('channelId');
  if (channel != 'msteams') {
    return TeamsGateDecision._reject(403, 'channel $channel is not msteams');
  }
  if (!key.endorsements.contains(channel)) {
    return const TeamsGateDecision._reject(
      403,
      'signing key not endorsed for msteams',
    );
  }

  // Microsoft's docs name the claim `serviceUrl`, and the tokens it sends
  // spell it `serviceurl`; either is taken. Its absence is refused, though
  // one 2026 Microsoft page checks it only "when present": it is the one
  // thing binding this token to this body.
  final serviceUrl = a.string('serviceUrl');
  final claimed =
      claims.stringOrNull('serviceurl') ?? claims.stringOrNull('serviceUrl');
  if (claimed == null) {
    return const TeamsGateDecision._reject(401, 'token has no serviceurl');
  }
  if (claimed != serviceUrl) {
    return const TeamsGateDecision._reject(
      401,
      'serviceurl claim does not match the activity',
    );
  }

  final conversation = a.object('conversation');
  final tenant =
      a
          .objectOrNull('channelData')
          ?.objectOrNull('tenant')
          ?.stringOrNull('id') ??
      conversation.stringOrNull('tenantId');
  if (spec.tenantAllowlist.isNotEmpty &&
      (tenant == null || !spec.tenantAllowlist.contains(tenant))) {
    return TeamsGateDecision._reject(403, 'tenant $tenant not allowed');
  }

  final type = a.string('type');
  final name = a.stringOrNull('name');
  final seenKey = jsonEncode([conversation.string('id'), a.string('id')]);
  final invokeResponse = type == 'invoke' && spec.wakeInvokes.contains(name)
      ? JsonObject.of({
          'statusCode': 200,
          'type': 'application/vnd.microsoft.activity.message',
          'value': spec.acknowledgement,
        })
      : null;

  if (hasSeen?.call(seenKey) ?? false) {
    return TeamsGateDecision._(
      TeamsGateOutcome.ignore,
      'activity already seen',
      invokeResponse: invokeResponse,
      seenKey: seenKey,
    );
  }
  if (invokeResponse == null && !spec.wakeActivityTypes.contains(type)) {
    return TeamsGateDecision._(
      TeamsGateOutcome.ignore,
      type == 'invoke' ? 'quiet invoke $name' : 'quiet activity $type',
      seenKey: seenKey,
    );
  }
  return TeamsGateDecision._(
    TeamsGateOutcome.trigger,
    type == 'invoke' ? 'invoke $name' : type,
    doorbell: _doorbell(a, type, name, tenant, conversation),
    invokeResponse: invokeResponse,
    seenKey: seenKey,
  );
}

JsonObject _doorbell(
  JsonObject a,
  String type,
  String? name,
  String? tenant,
  JsonObject conversation,
) {
  final from = a.objectOrNull('from');
  List<String>? ids(String k) =>
      a.objectsOrNull(k)?.map((m) => m.string('id')).toList();
  return JsonObject.of({
    'event': _event(type, name),
    'tenant': ?tenant,
    'conversation': conversation.string('id'),
    'conversation_type': ?conversation.stringOrNull('conversationType'),
    'activity': a.string('id'),
    'reply_to': ?a.stringOrNull('replyToId'),
    'service_url': a.string('serviceUrl'),
    'timestamp': ?a.stringOrNull('timestamp'),
    'from': ?from?.stringOrNull('id'),
    'from_aad_object_id': ?from?.stringOrNull('aadObjectId'),
    'recipient': ?a.objectOrNull('recipient')?.stringOrNull('id'),
    'text': ?a.stringOrNull('text'),
    'value': ?a.objectOrNull('value'),
    if (type == 'invoke') 'name': ?name,
    'event_type': ?a.objectOrNull('channelData')?.stringOrNull('eventType'),
    'action': ?a.stringOrNull('action'),
    'members_added': ?ids('membersAdded'),
    'members_removed': ?ids('membersRemoved'),
  });
}

/// `teams_` and the activity type in snake case; a card action by its own
/// name, since it is the one invoke the module is built around.
String _event(String type, String? name) => switch (type) {
  'invoke' when name == 'adaptiveCard/action' => 'teams_card_action',
  'invoke' => 'teams_invoke',
  _ =>
    'teams_${type.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}')}',
};

sealed class _Check {}

final class _Verified extends _Check {
  _Verified(this.claims, this.key);
  final JsonObject claims;
  final BotFrameworkKey key;
}

final class _Refused extends _Check {
  _Refused(this.reason);
  final String reason;
}

/// The token's claims, if Microsoft signed it for this bot and it is in
/// date. The signature is checked before any claim is believed.
_Check _verify(
  String token, {
  required BotFrameworkKeys keys,
  required String appId,
  required DateTime now,
  required Duration skew,
}) {
  final parts = token.split('.');
  if (parts.length != 3) return _Refused('token is not three parts');
  try {
    final header = _segment(parts[0]);
    // RS256 exactly. A token that names `none`, or an HMAC keyed with
    // something public, is the classic way past a verifier that trusts the
    // header's choice of algorithm.
    final alg = header.stringOrNull('alg');
    if (alg != 'RS256') return _Refused('token alg $alg is not RS256');
    final kid = header.stringOrNull('kid') ?? header.stringOrNull('x5t');
    if (kid == null) return _Refused('token names no key');
    final key = keys.byId(kid);
    if (key == null) return _Refused('token key $kid is not in the key set');

    final signature = _bytes(parts[2]);
    // Checked here so that the signer is only ever handed a block of the
    // size it expects.
    if (signature.length != (key.key.modulus!.bitLength + 7) ~/ 8) {
      return _Refused('signature is the wrong length for its key');
    }
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(false, PublicKeyParameter<RSAPublicKey>(key.key));
    if (!signer.verifySignature(
      utf8.encode('${parts[0]}.${parts[1]}'),
      RSASignature(signature),
    )) {
      return _Refused('bad signature');
    }

    final claims = _segment(parts[1]);
    final iss = claims.stringOrNull('iss');
    if (iss != botFrameworkIssuer) return _Refused('token issuer $iss');
    final aud = claims.raw('aud');
    if (!(aud == appId || (aud is List && aud.contains(appId)))) {
      return _Refused('token audience is not this bot');
    }
    final seconds = now.millisecondsSinceEpoch / 1000;
    final exp = claims.numberOrNull('exp');
    if (exp == null) return _Refused('token has no expiry');
    if (seconds > exp + skew.inSeconds) {
      return _Refused('token expired ${(seconds - exp).round()}s ago');
    }
    final nbf = claims.numberOrNull('nbf');
    if (nbf != null && seconds < nbf - skew.inSeconds) {
      return _Refused('token not valid for ${(nbf - seconds).round()}s');
    }
    return _Verified(claims, key);
  } on FormatException catch (e) {
    return _Refused('token: ${e.message}');
  }
}

/// A JWT segment decoded to a JSON object.
JsonObject _segment(String s) => JsonObject.decode(utf8.decode(_bytes(s)));

/// A base64url segment, padded or not, as bytes.
Uint8List _bytes(String s) => base64Url.decode(base64Url.normalize(s));
