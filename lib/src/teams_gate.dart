/// Decides whether an inbound Teams delivery is authentic, and what the relay
/// should do with it.
///
/// It is pure: the key set is the caller's, so every case is testable without a clock, a socket, or Microsoft. Four things about it
/// are forced by Teams:
///
/// 1. AUTHENTICATION is a JWT that Microsoft signs with a private key and the
///    gate checks against Microsoft's published public keys. The gate holds
///    no secret, only the app ids of the bots it serves; a token's audience
///    names exactly one of them, and that is the bot the activity is for.
///
/// 2. THE TOKEN VOUCHES FOR THE SENDER, NOT THE BODY. No documented check of
///    it touches the body. The `serviceurl` claim matched against the
///    activity is the only thing tying the two together. So whoever runs the
///    relay is trusted with content, in any design.
///
/// 3. AN EVENT CARRIES CONTENT (Nick, 2026-11-06). A card submission
///    exists nowhere but this request, and nothing can read a one-to-one
///    chat back short of permission over every chat in the tenant, so there
///    is nothing to fetch later. Text and submitted values ride in the
///    [TeamsEvent].
///
/// 4. REPEATS ARE KEYED BY ACTIVITY. What arrives is acted on, so the same
///    activity must not be acted on twice. The signature can't be the key:
///    the Bot Connector reuses one token across many deliveries until it
///    expires. The key is the conversation id with the activity id. Teams
///    also re-sends anything it gets no response to within 15 seconds, so
///    duplicates are ordinary traffic, not only attacks.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/signers/rsa_signer.dart';

import 'bot_framework_keys.dart';
import 'teams_event.dart';
import 'teams_ids.dart';

/// The issuer of every token the Bot Connector sends to a bot.
const botFrameworkIssuer = 'https://api.botframework.com';

/// What the caller should do.
enum TeamsGateOutcome {
  /// Hand [TeamsGateDecision.event] on; respond with 200, with
  /// [TeamsGateDecision.invokeResponse] as the body when there is one.
  trigger,

  /// Authentic but not for waking anyone: a quiet activity type. Respond
  /// with 200, still with [TeamsGateDecision.invokeResponse] as the body
  /// when there is one.
  ignore,

  /// Refused. Respond with [TeamsGateDecision.status] and never say why in
  /// the body; the log may.
  reject,
}

final class TeamsGateDecision {
  const TeamsGateDecision._(
    this.outcome,
    this.reason, {
    this.status = 200,
    this.event,
    this.invokeResponse,
  });

  const TeamsGateDecision._reject(int status, String reason)
    : this._(TeamsGateOutcome.reject, reason, status: status);

  final TeamsGateOutcome outcome;

  /// Operator-facing, logged. A rejection reason in a response body is a
  /// hint to whoever is guessing.
  final String reason;

  /// The HTTP status to respond with: 200 unless refused. 401 for a request
  /// that is not from the Bot Connector, 403 for an authentic one this bot
  /// won't take (a key not endorsed for Teams, a tenant not allowed), 400 for
  /// an authentic activity that isn't one, 413 for a body over the cap.
  final int status;

  /// What happened, present iff [outcome] is [TeamsGateOutcome.trigger].
  final TeamsEvent? event;

  /// The body of the response to an invoke. Teams waits for it before
  /// showing the person anything, and the agent is too far away to respond
  /// in time, so the gate responds with a fixed body: an acknowledgement
  /// for a card action, which the agent edits afterwards, or the invoke's
  /// entry in [TeamsSourceSpec.invokeResponses]. The same for every copy
  /// of one invoke Teams sends.
  final JsonObject? invokeResponse;

  bool get shouldWake => outcome == TeamsGateOutcome.trigger;
}

final class TeamsSourceSpec {
  const TeamsSourceSpec({
    required this.botAppIds,
    this.tenantAllowlist = const {},
    this.wakeActivityTypes = const {
      'message',
      'conversationUpdate',
      'installationUpdate',
      'messageUpdate',
      'messageDelete',
    },
    this.wakeInvokes = const {
      'adaptiveCard/action',
      'composeExtension/submitAction',
    },
    this.acknowledgement = 'Got it',
    this.invokeResponses = const {},
  });

  /// The app ids of the bots this endpoint serves: every token's audience
  /// must name exactly one. Empty is a configuration error, and the gate
  /// refuses rather than opens.
  final Set<BotAppId> botAppIds;

  /// Tenants whose activities are taken. Empty means "any tenant whose
  /// activity is correctly signed", which is only ever right in tests.
  final Set<String> tenantAllowlist;

  /// Activity types that wake the receiver. `conversationUpdate` and
  /// `installationUpdate` are among them because they carry what the agent
  /// needs to message a conversation first: its service URL, id and tenant.
  final Set<String> wakeActivityTypes;

  /// Invoke names that wake the receiver. A card action is responded to
  /// with [acknowledgement]; any other with its entry in [invokeResponses],
  /// or with no body.
  final Set<String> wakeInvokes;

  /// What Teams shows after a card action, before the agent edits the card.
  final String acknowledgement;

  /// Fixed response bodies by invoke name, given whether or not the invoke
  /// wakes anyone: how a dialog opens with no agent asked, as
  /// `composeExtension/fetchTask` answered with a [teamsDialog].
  final Map<String, JsonObject> invokeResponses;
}

/// The response to a `composeExtension/fetchTask` that opens [card], an
/// Adaptive Card, as a dialog titled [title]. Its submission arrives as a
/// `composeExtension/submitAction`, read as a [TeamsMessageActionSubmit].
JsonObject teamsDialog({required String title, required JsonObject card}) =>
    JsonObject.of({
      'task': {
        'type': 'continue',
        'value': {
          'title': title,
          'card': {
            'contentType': 'application/vnd.microsoft.card.adaptive',
            'content': card.asUncheckedMap(),
          },
        },
      },
    });

/// What the headers alone say about a delivery: a token the gate believes,
/// or a refusal.
sealed class TeamsTokenCheck {}

/// A bearer token Microsoft signed for one of the bots, in date. Made only
/// by [teamsToken], and taken by [teamsGateBody], which still has to match
/// its `serviceurl` claim and its [bot] against the activity.
final class TeamsToken extends TeamsTokenCheck {
  TeamsToken._(this._claims, this._key, this.bot);
  final JsonObject _claims;
  final BotFrameworkKey _key;

  /// The bot the token's audience names.
  final BotAppId bot;
}

/// A delivery refused on its headers: [decision] is a 401, and no body need
/// be read.
final class TeamsTokenRefused extends TeamsTokenCheck {
  TeamsTokenRefused._(this.decision);
  final TeamsGateDecision decision;
}

/// The whole gate, for a delivery whose body is already in hand: the token
/// from [teamsToken], then the body from [teamsGateBody].
TeamsGateDecision teamsGate({
  required TeamsSourceSpec spec,
  required BotFrameworkKeys keys,
  required Map<String, String> headers,
  required List<int> body,
  required DateTime now,
  Duration maxClockSkew = const Duration(minutes: 5),
  int maxBodyBytes = 1024 * 1024,
}) => switch (teamsToken(
  spec: spec,
  keys: keys,
  headers: headers,
  now: now,
  maxClockSkew: maxClockSkew,
)) {
  TeamsTokenRefused(:final decision) => decision,
  final TeamsToken token => teamsGateBody(
    spec: spec,
    token: token,
    body: body,
    maxBodyBytes: maxBodyBytes,
  ),
};

/// The checks the headers alone can make, so a sender with no valid token
/// is refused before a byte of its body is read: a token is present, signed
/// by one of [keys], from the Bot Connector, in date, and for exactly one of
/// the bots.
TeamsTokenCheck teamsToken({
  required TeamsSourceSpec spec,
  required BotFrameworkKeys keys,
  required Map<String, String> headers,
  required DateTime now,
  Duration maxClockSkew = const Duration(minutes: 5),
}) {
  // FAIL CLOSED on no app ids: a deploy that forgot an env var becomes a
  // refuser.
  if (spec.botAppIds.isEmpty) {
    return TeamsTokenRefused._(
      const TeamsGateDecision._reject(401, 'no bot app ids configured'),
    );
  }
  final auth = {
    for (final e in headers.entries) e.key.toLowerCase(): e.value,
  }['authorization'];
  if (auth == null || !auth.startsWith('Bearer ')) {
    return TeamsTokenRefused._(
      const TeamsGateDecision._reject(401, 'no bearer token'),
    );
  }
  return switch (_verify(
    auth.substring('Bearer '.length).trim(),
    keys: keys,
    botAppIds: spec.botAppIds,
    now: now,
    skew: maxClockSkew,
  )) {
    _Refused(:final reason) => TeamsTokenRefused._(
      TeamsGateDecision._reject(401, reason),
    ),
    _Verified(:final claims, :final key, :final bot) => TeamsToken._(
      claims,
      key,
      bot,
    ),
  };
}

/// The checks that need the body, for a delivery whose [token] passed: what
/// the activity is, and whether it is the one the token was sent with, as
/// far as the `serviceurl` claim can tell.
TeamsGateDecision teamsGateBody({
  required TeamsSourceSpec spec,
  required TeamsToken token,
  required List<int> body,
  int maxBodyBytes = 1024 * 1024,
}) {
  if (body.length > maxBodyBytes) {
    return TeamsGateDecision._reject(413, 'body ${body.length}b over cap');
  }
  final JsonObject activity;
  try {
    activity = JsonObject.decode(utf8.decode(body));
  } on FormatException {
    return const TeamsGateDecision._reject(400, 'body is not a JSON object');
  }
  try {
    return _decide(spec, activity, token);
  } on FormatException catch (e) {
    return TeamsGateDecision._reject(400, 'activity: ${e.message}');
  }
}

TeamsGateDecision _decide(
  TeamsSourceSpec spec,
  JsonObject a,
  TeamsToken token,
) {
  final TeamsToken(_claims: claims, _key: key) = token;
  // The endorsement is what makes channelId trustworthy: a key Microsoft
  // has not endorsed for Teams may not sign a Teams activity.
  final channel = a.string('channelId');
  // wire-ok: Bot Framework's channelId; this is the one check made of it.
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

  // The token says which bot it was sent to; the body's recipient is only
  // the body's word. Held to the token, so one bot's token can't carry an
  // activity addressed to another.
  final recipient = switch (a.objectOrNull('recipient')?.stringOrNull('id')) {
    final s? => TeamsUserId.parse(s),
    null => null,
  };
  if ((recipient == null ? null : BotAppId.ofChannelAccount(recipient)) !=
      token.bot) {
    return const TeamsGateDecision._reject(
      401,
      'recipient is not the bot the token is for',
    );
  }

  final conversation = a.object('conversation');
  final tenant = _tenant(a, conversation);
  if (spec.tenantAllowlist.isNotEmpty &&
      (tenant == null ||
          !spec.tenantAllowlist.any((t) => t.toLowerCase() == tenant))) {
    return TeamsGateDecision._reject(403, 'tenant $tenant not allowed');
  }

  final type = a.string('type');
  final name = a.stringOrNull('name');
  // wire-ok: Teams' activity type, an open set; read once here.
  final isInvoke = type == 'invoke';
  // A sign-in invoke carries the person's access token or a sign-in code,
  // and the relay records what the gate takes, for good. This bot asks no
  // one to sign in, so it takes none of them.
  // wire-ok: Teams' invoke names, an open set; this prefix is all of sign-in.
  if (isInvoke && (name?.startsWith('signin/') ?? false)) {
    return TeamsGateDecision._reject(403, 'sign-in invoke $name not taken');
  }
  final wakes = isInvoke
      ? spec.wakeInvokes.contains(name)
      : spec.wakeActivityTypes.contains(type);
  final invokeResponse = !isInvoke
      ? null
      : spec.invokeResponses[name] ??
            // wire-ok: the one invoke the acknowledgement's shape is for.
            (wakes && name == 'adaptiveCard/action'
                ? JsonObject.of({
                    'statusCode': 200,
                    'type': 'application/vnd.microsoft.activity.message',
                    'value': spec.acknowledgement,
                  })
                : null);

  if (!wakes) {
    return TeamsGateDecision._(TeamsGateOutcome.ignore, switch ((
      isInvoke,
      invokeResponse,
    )) {
      (false, _) => 'quiet activity $type',
      (true, null) => 'quiet invoke $name',
      (true, _) => 'answered invoke $name',
    }, invokeResponse: invokeResponse);
  }
  final event = _read(a, type, name, tenant, conversation);
  if (event == null) {
    return TeamsGateDecision._(
      TeamsGateOutcome.ignore,
      'no event is read from $type',
      invokeResponse: invokeResponse,
    );
  }
  return TeamsGateDecision._(
    TeamsGateOutcome.trigger,
    isInvoke ? 'invoke $name' : type,
    event: event,
    invokeResponse: invokeResponse,
  );
}

/// The event in a body the relay recorded: the same reading the gate gives
/// an activity it takes, without the gate's checks.
///
/// It trusts that [body] passed [teamsGate] before it was recorded, and
/// checks none of that again: not the token, its `serviceurl` claim, the
/// channel, nor the tenant allowlist. The relay records every body the gate
/// takes, whether or not an event is read from it, so this is for reading
/// those back, never for anything that came any other way.
///
/// The same activity can be recorded more than once: Teams sends again when
/// it has no 200 in time, and the relay records every copy. Two records are
/// one activity when their conversation, activity type, id and timestamp
/// all match. Conversation, type and id are enough to tell a message, a
/// join or a card press from another; an edit or a delete carries its
/// message's id, so telling it apart takes the timestamp too.
///
/// Null for an activity type no event is read as. Throws a
/// [FormatException] for a body that isn't an activity, which a recorded
/// one never is.
TeamsEvent? teamsRecordedEvent(List<int> body) {
  final a = JsonObject.decode(utf8.decode(body));
  final conversation = a.object('conversation');
  return _read(
    a,
    a.string('type'),
    a.stringOrNull('name'),
    _tenant(a, conversation),
    conversation,
  );
}

/// The activity's tenant. A tenant id is a GUID, compared and passed on in
/// lower case, as the actor id `teams:<tenant>/<object id>` writes it:
/// whether Teams always sends it lower case is not something the docs
/// promise.
String? _tenant(JsonObject a, JsonObject conversation) =>
    (a
                .objectOrNull('channelData')
                ?.objectOrNull('tenant')
                ?.stringOrNull('id') ??
            conversation.stringOrNull('tenantId'))
        ?.toLowerCase();

/// The activity read into what happened. Null for an activity type no event
/// is read as.
TeamsEvent? _read(
  JsonObject a,
  String type,
  String? name,
  String? tenant,
  JsonObject conversation,
) {
  final id = a.string('id');
  final conversationId = conversation.string('id');
  final serviceUrl = Uri.parse(a.string('serviceUrl'));
  final conversationType = conversation.stringOrNull('conversationType');
  final timestamp = a.stringOrNull('timestamp');
  // Each id is read into its type here, where it enters, and nowhere after.
  // One not in its proper form is read as absent: a sender Teams names
  // wrongly is no one, rather than someone made up.
  TeamsUserId? user(String? s) => s == null ? null : TeamsUserId.parse(s);
  final from = a.objectOrNull('from');
  final fromId = user(from?.stringOrNull('id'));
  final fromAadObjectId = switch (from?.stringOrNull('aadObjectId')) {
    final s? => EntraObjectId.parse(s),
    null => null,
  };
  // The gate has held the recipient to the token's audience by now, and a
  // recorded body passed the gate, so a recipient that names no bot isn't
  // an activity.
  final bot = switch (user(a.objectOrNull('recipient')?.stringOrNull('id'))) {
    final r? => BotAppId.ofChannelAccount(r),
    null => null,
  };
  if (bot == null) throw const FormatException('recipient is not a bot');
  final text = a.stringOrNull('text');
  // As they came: @-mentions, and the quoted-reply entity that says which
  // earlier message a reply quotes. That is how a free-text reply in a chat
  // names the node it is about; TeamsMessage.quote reads it.
  final entities = a.objectsOrNull('entities');
  final channelData = a.objectOrNull('channelData');
  final channelEventType = channelData?.stringOrNull('eventType');
  final channel = channelData?.objectOrNull('channel')?.stringOrNull('id');
  final team = channelData?.objectOrNull('team')?.stringOrNull('id');
  List<TeamsUserId> ids(String k) => [
    for (final m in a.objectsOrNull(k) ?? const <JsonObject>[])
      ?user(m.string('id')),
  ];
  // wire-ok: the activity type and invoke name, parsed here into TeamsEvent.
  return switch (type) {
    'message' => TeamsMessage(
      conversation: conversationId,
      id: id,
      serviceUrl: serviceUrl,
      tenant: tenant,
      conversationType: conversationType,
      timestamp: timestamp,
      from: fromId,
      fromAadObjectId: fromAadObjectId,
      bot: bot,
      channel: channel,
      team: team,
      text: text,
      entities: entities,
      replyTo: a.stringOrNull('replyToId'),
    ),
    'messageUpdate' => TeamsMessageUpdate(
      conversation: conversationId,
      id: id,
      serviceUrl: serviceUrl,
      tenant: tenant,
      conversationType: conversationType,
      timestamp: timestamp,
      from: fromId,
      fromAadObjectId: fromAadObjectId,
      bot: bot,
      channel: channel,
      team: team,
      text: text,
      entities: entities,
      channelEventType: channelEventType,
    ),
    'messageDelete' => TeamsMessageDelete(
      conversation: conversationId,
      id: id,
      serviceUrl: serviceUrl,
      tenant: tenant,
      conversationType: conversationType,
      timestamp: timestamp,
      from: fromId,
      fromAadObjectId: fromAadObjectId,
      bot: bot,
      channel: channel,
      team: team,
      channelEventType: channelEventType,
    ),
    // wire-ok: the activity type and invoke name, parsed here into TeamsEvent.
    'invoke' when name == 'adaptiveCard/action' => TeamsCardAction(
      conversation: conversationId,
      id: id,
      serviceUrl: serviceUrl,
      tenant: tenant,
      conversationType: conversationType,
      timestamp: timestamp,
      from: fromId,
      fromAadObjectId: fromAadObjectId,
      bot: bot,
      channel: channel,
      team: team,
      card: a.stringOrNull('replyToId'),
      value: a.objectOrNull('value'),
    ),
    // wire-ok: the invoke name, parsed here into TeamsEvent.
    'invoke' when name == 'composeExtension/submitAction' =>
      TeamsMessageActionSubmit(
        conversation: conversationId,
        id: id,
        serviceUrl: serviceUrl,
        tenant: tenant,
        conversationType: conversationType,
        timestamp: timestamp,
        from: fromId,
        fromAadObjectId: fromAadObjectId,
        bot: bot,
        channel: channel,
        team: team,
        command: a.objectOrNull('value')?.stringOrNull('commandId'),
        message: a
            .objectOrNull('value')
            ?.objectOrNull('messagePayload')
            ?.stringOrNull('id'),
        data: a.objectOrNull('value')?.objectOrNull('data'),
      ),
    'invoke' => TeamsInvoke(
      conversation: conversationId,
      id: id,
      serviceUrl: serviceUrl,
      tenant: tenant,
      conversationType: conversationType,
      timestamp: timestamp,
      from: fromId,
      fromAadObjectId: fromAadObjectId,
      bot: bot,
      channel: channel,
      team: team,
      name: name,
      value: a.objectOrNull('value'),
    ),
    'conversationUpdate' => TeamsConversationUpdate(
      conversation: conversationId,
      id: id,
      serviceUrl: serviceUrl,
      tenant: tenant,
      conversationType: conversationType,
      timestamp: timestamp,
      from: fromId,
      fromAadObjectId: fromAadObjectId,
      bot: bot,
      channel: channel,
      team: team,
      added: ids('membersAdded'),
      removed: ids('membersRemoved'),
    ),
    'installationUpdate' => TeamsInstallationUpdate(
      conversation: conversationId,
      id: id,
      serviceUrl: serviceUrl,
      tenant: tenant,
      conversationType: conversationType,
      timestamp: timestamp,
      from: fromId,
      fromAadObjectId: fromAadObjectId,
      bot: bot,
      channel: channel,
      team: team,
      action: a.stringOrNull('action'),
    ),
    _ => null,
  };
}

sealed class _Check {}

final class _Verified extends _Check {
  _Verified(this.claims, this.key, this.bot);
  final JsonObject claims;
  final BotFrameworkKey key;
  final BotAppId bot;
}

final class _Refused extends _Check {
  _Refused(this.reason);
  final String reason;
}

/// The token's claims and the bot it is for, if Microsoft signed it for
/// exactly one of [botAppIds] and it is in date. The signature is checked
/// before any claim is believed.
_Check _verify(
  String token, {
  required BotFrameworkKeys keys,
  required Set<BotAppId> botAppIds,
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
    // wire-ok: the JWT header's alg, checked against the one we accept.
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
    // Two of ours in one audience would leave which bot it is for to the
    // body, which the token doesn't vouch for.
    final bots = {
      for (final s in switch (claims.raw('aud')) {
        final String one => [one],
        final List<Object?> many => many.whereType<String>(),
        _ => const <String>[],
      })
        if (BotAppId.parse(s) case final b? when botAppIds.contains(b)) b,
    };
    if (bots.length != 1) {
      return _Refused(
        bots.isEmpty
            ? 'token audience is none of these bots'
            : 'token audience names ${bots.length} of these bots',
      );
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
    return _Verified(claims, key, bots.single);
  } on FormatException catch (e) {
    return _Refused('token: ${e.message}');
  }
}

/// A JWT segment decoded to a JSON object.
JsonObject _segment(String s) => JsonObject.decode(utf8.decode(_bytes(s)));

/// A base64url segment, padded or not, as bytes.
Uint8List _bytes(String s) => base64Url.decode(base64Url.normalize(s));
