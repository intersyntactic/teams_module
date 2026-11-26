/// Decides whether an inbound Teams delivery is authentic, and what of it
/// the relay records.
///
/// It is pure: the key set is the caller's, so every case is testable
/// without a clock, a socket, or Microsoft. Five things about it are forced
/// by Teams:
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
/// 3. AN EVENT CARRIES CONTENT. A card submission exists nowhere but this
///    request, and nothing can read a one-to-one chat back short of
///    permission over every chat in the tenant, so there is nothing to fetch
///    later. Text rides in the [TeamsEvent].
///
/// 4. AN ACTIVITY CAN CARRY A CREDENTIAL in fields this module never reads:
///    a person's access token in a sign-in invoke, a single-sign-on token on
///    a card press, a pre-authorised download link on a file. So the relay
///    records the [TeamsEvent], a closed projection, never the body, and an
///    activity of a kind that isn't one of its cases is refused unrecorded.
///
/// 5. REPEATS ARE KEYED BY ACTIVITY. Teams re-sends anything it gets no
///    response to within 15 seconds, so the same activity can be recorded
///    more than once; the projection keeps its conversation and id, and the
///    docking station decides each once.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';
import 'package:is_relay/is_relay.dart' show RefusalStatus;
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/signers/rsa_signer.dart';

import 'bot_framework_keys.dart';
import 'teams_event.dart';
import 'teams_ids.dart';

/// The issuer of every token the Bot Connector sends to a bot.
const botFrameworkIssuer = 'https://api.botframework.com';

/// Why the gate refused a delivery. A fixed set, each with its status and a
/// fixed reason to log, so nothing a sender wrote ever reaches the log.
enum TeamsRefusal {
  /// A deploy that forgot its app ids refuses rather than opens.
  noBotAppIds(RefusalStatus.unauthorized, 'no bot app ids configured'),
  noBearerToken(RefusalStatus.unauthorized, 'no bearer token'),
  tokenUnreadable(RefusalStatus.unauthorized, 'token is not a readable JWT'),
  tokenAlgorithm(RefusalStatus.unauthorized, 'token alg is not RS256'),
  tokenNamesNoKey(RefusalStatus.unauthorized, 'token names no key'),
  tokenKeyUnknown(RefusalStatus.unauthorized, 'token key is not in the set'),
  badSignature(RefusalStatus.unauthorized, 'bad signature'),
  tokenIssuer(RefusalStatus.unauthorized, 'token is not the Bot Connector\'s'),
  tokenAudience(
    RefusalStatus.unauthorized,
    'token audience is not exactly one of these bots',
  ),
  tokenNoExpiry(RefusalStatus.unauthorized, 'token has no expiry'),
  tokenExpired(RefusalStatus.unauthorized, 'token expired'),
  tokenNotYetValid(RefusalStatus.unauthorized, 'token not yet valid'),
  bodyTooLarge(RefusalStatus.payloadTooLarge, 'body over the cap'),
  bodyNotJson(RefusalStatus.badRequest, 'body is not a JSON object'),
  activityMalformed(RefusalStatus.badRequest, 'activity is not in its form'),
  notTeams(RefusalStatus.forbidden, 'channel is not msteams'),

  /// The endorsement is what makes `channelId` trustworthy.
  keyNotEndorsed(RefusalStatus.forbidden, 'key not endorsed for msteams'),
  noServiceUrlClaim(RefusalStatus.unauthorized, 'token has no serviceurl'),
  serviceUrlMismatch(
    RefusalStatus.unauthorized,
    'serviceurl claim does not match the activity',
  ),
  recipientNotTokenBot(
    RefusalStatus.unauthorized,
    'recipient is not the bot the token is for',
  ),
  tenantNotAllowed(RefusalStatus.forbidden, 'tenant not allowed'),

  /// Authentic, but not one of [TeamsEvent]'s cases, so there is nothing
  /// the relay may record of it.
  kindNotRecorded(RefusalStatus.forbidden, 'activity kind is not recorded');

  const TeamsRefusal(this.status, this.reason);

  /// What the relay answers.
  final RefusalStatus status;

  /// Logged, never sent: a reason in a response is a hint to whoever is
  /// guessing.
  final String reason;
}

/// What the gate decided about a delivery.
sealed class TeamsGateDecision {
  const TeamsGateDecision();
}

/// Authentic and of a recorded kind: record [event]'s projection, then
/// answer 200 with [response] as the body when there is one.
final class TeamsActivityTaken extends TeamsGateDecision {
  const TeamsActivityTaken(this.event, {this.response});

  final TeamsEvent event;

  /// The body of the response to an invoke. Teams waits for it before
  /// showing the person anything, and the agent is too far away to respond
  /// in time, so it is fixed by the kind: an acknowledgement for a card
  /// press, which the agent edits afterwards, or the dialog a message action
  /// opens. The same for every copy of one invoke Teams sends.
  final JsonObject? response;
}

/// Refused, for [refusal]: answered its status, recorded nowhere.
final class TeamsActivityRefused extends TeamsGateDecision {
  const TeamsActivityRefused(this.refusal);
  final TeamsRefusal refusal;
}

final class TeamsSourceSpec {
  const TeamsSourceSpec({
    required this.botAppIds,
    this.tenantAllowlist = const {},
    this.acknowledgement = 'Got it',
    this.callSettingsDialog,
  });

  /// The app ids of the bots this endpoint serves: every token's audience
  /// must name exactly one. Empty is a configuration error, and the gate
  /// refuses rather than opens.
  final Set<BotAppId> botAppIds;

  /// Tenants whose activities are taken. Empty means "any tenant whose
  /// activity is correctly signed", which is only ever right in tests.
  final Set<String> tenantAllowlist;

  /// What Teams shows after a card press, before the agent edits the card.
  final String acknowledgement;

  /// The response that opens the call settings dialog, as [teamsDialog]
  /// makes it. With none, opening call settings is refused.
  final JsonObject? callSettingsDialog;
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

/// A delivery refused on its headers: no body need be read.
final class TeamsTokenRefused extends TeamsTokenCheck {
  TeamsTokenRefused._(this.refusal);
  final TeamsRefusal refusal;
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
  TeamsTokenRefused(:final refusal) => TeamsActivityRefused(refusal),
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
  if (spec.botAppIds.isEmpty) {
    return TeamsTokenRefused._(TeamsRefusal.noBotAppIds);
  }
  final auth = {
    for (final e in headers.entries) e.key.toLowerCase(): e.value,
  }['authorization'];
  if (auth == null || !auth.startsWith('Bearer ')) {
    return TeamsTokenRefused._(TeamsRefusal.noBearerToken);
  }
  return switch (_verify(
    auth.substring('Bearer '.length).trim(),
    keys: keys,
    botAppIds: spec.botAppIds,
    now: now,
    skew: maxClockSkew,
  )) {
    _Refused(:final refusal) => TeamsTokenRefused._(refusal),
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
    return const TeamsActivityRefused(TeamsRefusal.bodyTooLarge);
  }
  final JsonObject activity;
  try {
    activity = JsonObject.decode(utf8.decode(body));
  } on FormatException {
    return const TeamsActivityRefused(TeamsRefusal.bodyNotJson);
  }
  try {
    return _decide(spec, activity, token);
  } on FormatException {
    return const TeamsActivityRefused(TeamsRefusal.activityMalformed);
  }
}

/// The event a projection the relay recorded holds, as
/// [TeamsEvent.fromProjection] reads it. Throws a [FormatException] for
/// bytes that aren't a projection this module writes, a raw activity among
/// them.
TeamsEvent teamsRecordedEvent(List<int> bytes) =>
    TeamsEvent.fromProjection(JsonObject.decode(utf8.decode(bytes)));

TeamsGateDecision _decide(
  TeamsSourceSpec spec,
  JsonObject a,
  TeamsToken token,
) {
  final TeamsToken(_claims: claims, _key: key) = token;
  final channel = a.string('channelId');
  // wire-ok: Bot Framework's channelId; this is the one check made of it.
  if (channel != 'msteams') {
    return const TeamsActivityRefused(TeamsRefusal.notTeams);
  }
  if (!key.endorsements.contains(channel)) {
    return const TeamsActivityRefused(TeamsRefusal.keyNotEndorsed);
  }

  // Microsoft's docs name the claim `serviceUrl`, and the tokens it sends
  // spell it `serviceurl`; either is taken. Its absence is refused, though
  // one 2026 Microsoft page checks it only "when present": it is the one
  // thing binding this token to this body.
  final serviceUrl = a.string('serviceUrl');
  final claimed =
      claims.stringOrNull('serviceurl') ?? claims.stringOrNull('serviceUrl');
  if (claimed == null) {
    return const TeamsActivityRefused(TeamsRefusal.noServiceUrlClaim);
  }
  if (claimed != serviceUrl) {
    return const TeamsActivityRefused(TeamsRefusal.serviceUrlMismatch);
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
    return const TeamsActivityRefused(TeamsRefusal.recipientNotTokenBot);
  }

  final conversation = a.object('conversation');
  final tenant = _tenant(a, conversation);
  if (spec.tenantAllowlist.isNotEmpty &&
      (tenant == null ||
          !spec.tenantAllowlist.any((t) => t.toLowerCase() == tenant))) {
    return const TeamsActivityRefused(TeamsRefusal.tenantNotAllowed);
  }
  return _project(spec, a, token.bot, tenant, conversation) ??
      const TeamsActivityRefused(TeamsRefusal.kindNotRecorded);
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

/// The activity as the [TeamsEvent] the relay records, with the response
/// its kind is answered with. Null for an activity of no recorded kind:
/// the one place an activity type or invoke name is read, so a kind is
/// recorded only by a case written here on purpose.
TeamsActivityTaken? _project(
  TeamsSourceSpec spec,
  JsonObject a,
  BotAppId bot,
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
  final text = a.stringOrNull('text');
  final entities = a.objectsOrNull('entities') ?? const <JsonObject>[];
  final channelData = a.objectOrNull('channelData');
  final channelEventType = channelData?.stringOrNull('eventType');
  final channel = channelData?.objectOrNull('channel')?.stringOrNull('id');
  final team = channelData?.objectOrNull('team')?.stringOrNull('id');
  final value = a.objectOrNull('value');
  List<TeamsUserId> ids(String k) => [
    for (final m in a.objectsOrNull(k) ?? const <JsonObject>[])
      ?user(m.string('id')),
  ];
  final type = a.string('type');
  final name = a.stringOrNull('name');
  // wire-ok: the activity type and invoke name, read here into TeamsEvent.
  return switch ((type, name)) {
    ('message', _) => TeamsActivityTaken(
      TeamsMessage(
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
        mentions: _mentions(entities),
        quote: _quote(entities),
        replyTo: a.stringOrNull('replyToId'),
        attachments: _attachments(a),
      ),
    ),
    ('messageUpdate', _) => TeamsActivityTaken(
      TeamsMessageUpdate(
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
        mentions: _mentions(entities),
        channelEventType: channelEventType,
      ),
    ),
    ('messageDelete', _) => TeamsActivityTaken(
      TeamsMessageDelete(
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
    ),
    ('invoke', 'adaptiveCard/action') => TeamsActivityTaken(
      TeamsCardAction(
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
        verb: CardActionVerb.parse(
          value?.objectOrNull('action')?.stringOrNull('verb'),
        ),
        trajectory: switch (value
            ?.objectOrNull('action')
            ?.objectOrNull('data')
            ?.stringOrNull('trajectory')) {
          final hex? => TrajectoryId.parse(hex),
          null => null,
        },
      ),
      response: JsonObject.of({
        'statusCode': 200,
        'type': 'application/vnd.microsoft.activity.message',
        'value': spec.acknowledgement,
      }),
    ),
    ('invoke', 'composeExtension/fetchTask') => switch ((
      TeamsMessageAction.parse(value?.stringOrNull('commandId')),
      spec.callSettingsDialog,
    )) {
      (TeamsMessageAction.callSettings, final dialog?) => TeamsActivityTaken(
        TeamsMessageActionOpen(
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
          command: TeamsMessageAction.callSettings,
          message: _messageActedOn(value),
        ),
        response: dialog,
      ),
      _ => null,
    },
    ('invoke', 'composeExtension/submitAction') =>
      switch (TeamsMessageAction.parse(value?.stringOrNull('commandId'))) {
        final command? => TeamsActivityTaken(
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
            command: command,
            message: _messageActedOn(value),
          ),
        ),
        null => null,
      },
    ('conversationUpdate', _) => TeamsActivityTaken(
      TeamsConversationUpdate(
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
    ),
    ('installationUpdate', _) => TeamsActivityTaken(
      TeamsInstallationUpdate(
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
        action: InstallationAction.parse(a.stringOrNull('action')),
      ),
    ),
    _ => null,
  };
}

/// The id of the message a message action was opened on.
String? _messageActedOn(JsonObject? value) =>
    value?.objectOrNull('messagePayload')?.stringOrNull('id');

// wire-ok: Teams' entity types, an open set; only these two are read.
const _mentionEntity = 'mention';
const _quotedReplyEntity = 'quotedReply';

/// The people and bots @-mentioned: each `mention` entity whose `mentioned`
/// names a channel account.
List<TeamsMention> _mentions(List<JsonObject> entities) => [
  for (final e in entities)
    if (e.stringOrNull('type') == _mentionEntity)
      if (e.objectOrNull('mentioned') case final m?)
        if (TeamsUserId.parse(m.stringOrNull('id') ?? '') case final id?)
          TeamsMention(id: id, name: m.stringOrNull('name')),
];

/// What a Reply quotes: the first `quotedReply` entity that names both a
/// message and its author. That is how a free-text reply in a chat names
/// the node it is about.
TeamsQuote? _quote(List<JsonObject> entities) {
  for (final e in entities) {
    if (e.stringOrNull('type') != _quotedReplyEntity) continue;
    final q = e.objectOrNull('quotedReply');
    final messageId = q?.stringOrNull('messageId');
    final senderId = switch (q?.stringOrNull('senderId')) {
      final s? => TeamsUserId.parse(s),
      null => null,
    };
    if (q == null || messageId == null || senderId == null) continue;
    return TeamsQuote(
      messageId: messageId,
      senderId: senderId,
      senderName: q.stringOrNull('senderName'),
      preview: q.stringOrNull('preview'),
    );
  }
  return null;
}

/// What a message carried, by reference: each attachment's type, name and
/// where it lives. Its content, and any `downloadUrl` inside it, is never
/// read.
List<TeamsAttachmentReference> _attachments(JsonObject a) => [
  for (final at in a.objectsOrNull('attachments') ?? const <JsonObject>[])
    if (at.stringOrNull('contentType') case final contentType?)
      TeamsAttachmentReference(
        contentType: contentType,
        name: at.stringOrNull('name'),
        contentUrl: _addressOnly(at.stringOrNull('contentUrl')),
      ),
];

/// [url]'s scheme, host, port and path only. A pre-authorised link carries
/// its grant in the query, and a URL can carry a password before its host,
/// so neither is kept. Null for no URL, or one with no host.
Uri? _addressOnly(String? url) => switch (Uri.tryParse(url ?? '')) {
  final u? when u.hasScheme && u.host.isNotEmpty => Uri(
    scheme: u.scheme,
    host: u.host,
    port: u.hasPort ? u.port : null,
    path: u.path,
  ),
  _ => null,
};

sealed class _Check {}

final class _Verified extends _Check {
  _Verified(this.claims, this.key, this.bot);
  final JsonObject claims;
  final BotFrameworkKey key;
  final BotAppId bot;
}

final class _Refused extends _Check {
  _Refused(this.refusal);
  final TeamsRefusal refusal;
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
  if (parts.length != 3) return _Refused(TeamsRefusal.tokenUnreadable);
  try {
    final header = _segment(parts[0]);
    // RS256 exactly. A token that names `none`, or an HMAC keyed with
    // something public, is the classic way past a verifier that trusts the
    // header's choice of algorithm.
    // wire-ok: the JWT header's alg, checked against the one we accept.
    if (header.stringOrNull('alg') != 'RS256') {
      return _Refused(TeamsRefusal.tokenAlgorithm);
    }
    final kid = header.stringOrNull('kid') ?? header.stringOrNull('x5t');
    if (kid == null) return _Refused(TeamsRefusal.tokenNamesNoKey);
    final key = keys.byId(kid);
    if (key == null) return _Refused(TeamsRefusal.tokenKeyUnknown);

    final signature = _bytes(parts[2]);
    // Checked here so that the signer is only ever handed a block of the
    // size it expects.
    if (signature.length != (key.key.modulus!.bitLength + 7) ~/ 8) {
      return _Refused(TeamsRefusal.badSignature);
    }
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(false, PublicKeyParameter<RSAPublicKey>(key.key));
    if (!signer.verifySignature(
      utf8.encode('${parts[0]}.${parts[1]}'),
      RSASignature(signature),
    )) {
      return _Refused(TeamsRefusal.badSignature);
    }

    final claims = _segment(parts[1]);
    if (claims.stringOrNull('iss') != botFrameworkIssuer) {
      return _Refused(TeamsRefusal.tokenIssuer);
    }
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
    if (bots.length != 1) return _Refused(TeamsRefusal.tokenAudience);
    final seconds = now.millisecondsSinceEpoch / 1000;
    final exp = claims.numberOrNull('exp');
    if (exp == null) return _Refused(TeamsRefusal.tokenNoExpiry);
    if (seconds > exp + skew.inSeconds) {
      return _Refused(TeamsRefusal.tokenExpired);
    }
    final nbf = claims.numberOrNull('nbf');
    if (nbf != null && seconds < nbf - skew.inSeconds) {
      return _Refused(TeamsRefusal.tokenNotYetValid);
    }
    return _Verified(claims, key, bots.single);
  } on FormatException {
    return _Refused(TeamsRefusal.tokenUnreadable);
  }
}

/// A JWT segment decoded to a JSON object.
JsonObject _segment(String s) => JsonObject.decode(utf8.decode(_bytes(s)));

/// A base64url segment, padded or not, as bytes.
Uint8List _bytes(String s) => base64Url.decode(base64Url.normalize(s));
