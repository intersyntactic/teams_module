import 'package:checked_json/checked_json.dart';
import 'package:is_shapes/is_shapes.dart';

import 'teams_ids.dart';

/// Teams' account of one activity, checked by the gate, and what the relay
/// records of it: [projection] is the whole of what is written, and
/// [TeamsEvent.fromProjection] reads it back. Each case is named for Teams'
/// own activity, since it is Teams' account of what happened, not a reading
/// of it.
///
/// Closed on purpose. Every field is one the module reads, or will read
/// for a purpose already named, and each is typed: there is no open
/// subtree, so a protocol field the module doesn't use is never written,
/// whatever Teams puts in it. Words a person types or submits are kept, since
/// they exist nowhere but the request that brought them.
sealed class TeamsEvent {
  const TeamsEvent({
    required this.conversation,
    required this.id,
    required this.serviceUrl,
    required this.bot,
    this.tenant,
    this.conversationType,
    this.timestamp,
    this.from,
    this.fromAadObjectId,
    this.channel,
    this.team,
  });

  /// The Entra tenant id, in lower case.
  final String? tenant;

  /// The conversation id.
  final String conversation;

  /// `personal`, `groupChat` or `channel`.
  final String? conversationType;

  /// The activity's id. Teams makes it unique only within [conversation],
  /// so [ref] is what names it, and a redelivery carries the same one.
  final String id;

  /// This activity by where it was said; null when Teams' ids aren't the
  /// kind [TeamsMessageRef] takes.
  TeamsMessageRef? get ref => TeamsMessageRef.of(conversation, id);

  /// The Bot Connector endpoint for the conversation's region.
  final Uri serviceUrl;

  final String? timestamp;

  /// The sender's channel account id.
  final TeamsUserId? from;

  /// The sender's Entra object id: a person's, never a bot's.
  final EntraObjectId? fromAadObjectId;

  /// The bot it was sent to: the token's audience, which the gate holds the
  /// activity's recipient to.
  final BotAppId bot;

  /// In a team, the channel it happened in, as Teams names it in
  /// `channelData`. A channel message's [conversation] is a thread in this
  /// channel: `<channel>;messageid=<the thread's first post>`.
  final String? channel;

  /// In a team, the team's id. It is the id of the team's first channel,
  /// where Teams sends a team-wide event such as the bot being added. That
  /// channel is created as General, but can be renamed.
  final String? team;

  /// Who sent it, as [teamsActor] names them.
  ActorId? get actor => teamsActor(tenant, user: from, entra: fromAadObjectId);

  _Kind get _kind;

  /// The fields this case adds, as recorded. A null or empty one is left out.
  Map<String, Object?> get _own;

  /// What the relay records for this activity, in place of its body: the
  /// projection's version, the case, and its fields, always in this order,
  /// so the same activity is always the same bytes.
  JsonObject projection() => JsonObject.of({
    _version: teamsProjectionVersion,
    _kindKey: _kind.asRecorded,
    'conversation': conversation,
    'id': id,
    'serviceUrl': serviceUrl.toString(),
    'bot': bot.value,
    'tenant': ?tenant,
    'conversationType': ?conversationType,
    'timestamp': ?timestamp,
    'from': ?from?.value,
    'fromAadObjectId': ?fromAadObjectId?.value,
    'channel': ?channel,
    'team': ?team,
    for (final MapEntry(:key, :value) in _own.entries)
      if (switch (value) {
        null => false,
        List(isEmpty: true) || Map(isEmpty: true) => false,
        _ => true,
      })
        key: value,
  });

  /// The event [projection] recorded. Strict: a projection of another
  /// version, an unknown case, a field no case has, or a field of the wrong
  /// type throws a [FormatException], so a record this module didn't write
  /// is never read as one it did.
  static TeamsEvent fromProjection(JsonObject p) {
    if (p.raw(_version) != teamsProjectionVersion) {
      throw FormatException('not a version $teamsProjectionVersion projection');
    }
    final kind = _Kind.parse(p.string(_kindKey));
    if (kind == null) throw const FormatException('unknown kind');
    final unknown = p.keys.where(
      (k) => !_commonKeys.contains(k) && !kind.ownKeys.contains(k),
    );
    if (unknown.isNotEmpty) {
      throw FormatException('fields no ${kind.asRecorded} has', unknown.first);
    }
    final conversation = p.string('conversation');
    final id = p.string('id');
    final serviceUrl = Uri.parse(p.string('serviceUrl'));
    final bot = _required(BotAppId.parse(p.string('bot')), 'bot');
    final tenant = p.stringOrNull('tenant');
    final conversationType = p.stringOrNull('conversationType');
    final timestamp = p.stringOrNull('timestamp');
    final from = _userOrNull(p.stringOrNull('from'), 'from');
    final fromAadObjectId = switch (p.stringOrNull('fromAadObjectId')) {
      final s? => _required(EntraObjectId.parse(s), 'fromAadObjectId'),
      null => null,
    };
    final channel = p.stringOrNull('channel');
    final team = p.stringOrNull('team');
    List<TeamsMention> mentions() => [
      for (final m in p.objectsOrNull('mentions') ?? const <JsonObject>[])
        TeamsMention._fromProjection(m),
    ];
    return switch (kind) {
      _Kind.message => TeamsMessage(
        conversation: conversation,
        id: id,
        serviceUrl: serviceUrl,
        bot: bot,
        tenant: tenant,
        conversationType: conversationType,
        timestamp: timestamp,
        from: from,
        fromAadObjectId: fromAadObjectId,
        channel: channel,
        team: team,
        text: p.stringOrNull('text'),
        mentions: mentions(),
        quote: switch (p.objectOrNull('quote')) {
          final q? => TeamsQuote._fromProjection(q),
          null => null,
        },
        replyTo: p.stringOrNull('replyTo'),
        attachments: [
          for (final a
              in p.objectsOrNull('attachments') ?? const <JsonObject>[])
            TeamsAttachmentReference._fromProjection(a),
        ],
      ),
      _Kind.messageUpdate => TeamsMessageUpdate(
        conversation: conversation,
        id: id,
        serviceUrl: serviceUrl,
        bot: bot,
        tenant: tenant,
        conversationType: conversationType,
        timestamp: timestamp,
        from: from,
        fromAadObjectId: fromAadObjectId,
        channel: channel,
        team: team,
        text: p.stringOrNull('text'),
        mentions: mentions(),
        channelEventType: p.stringOrNull('channelEventType'),
      ),
      _Kind.messageDelete => TeamsMessageDelete(
        conversation: conversation,
        id: id,
        serviceUrl: serviceUrl,
        bot: bot,
        tenant: tenant,
        conversationType: conversationType,
        timestamp: timestamp,
        from: from,
        fromAadObjectId: fromAadObjectId,
        channel: channel,
        team: team,
        channelEventType: p.stringOrNull('channelEventType'),
      ),
      _Kind.cardAction => TeamsCardAction(
        conversation: conversation,
        id: id,
        serviceUrl: serviceUrl,
        bot: bot,
        tenant: tenant,
        conversationType: conversationType,
        timestamp: timestamp,
        from: from,
        fromAadObjectId: fromAadObjectId,
        channel: channel,
        team: team,
        card: p.stringOrNull('card'),
        verb: switch (p.stringOrNull('verb')) {
          final v? => _required(CardActionVerb.parse(v), 'verb'),
          null => null,
        },
        trajectory: switch (p.stringOrNull('trajectory')) {
          final t? => _required(TrajectoryId.parse(t), 'trajectory'),
          null => null,
        },
      ),
      _Kind.messageActionOpen => TeamsMessageActionOpen(
        conversation: conversation,
        id: id,
        serviceUrl: serviceUrl,
        bot: bot,
        tenant: tenant,
        conversationType: conversationType,
        timestamp: timestamp,
        from: from,
        fromAadObjectId: fromAadObjectId,
        channel: channel,
        team: team,
        command: _command(p),
        message: p.stringOrNull('message'),
      ),
      _Kind.messageActionSubmit => TeamsMessageActionSubmit(
        conversation: conversation,
        id: id,
        serviceUrl: serviceUrl,
        bot: bot,
        tenant: tenant,
        conversationType: conversationType,
        timestamp: timestamp,
        from: from,
        fromAadObjectId: fromAadObjectId,
        channel: channel,
        team: team,
        command: _command(p),
        message: p.stringOrNull('message'),
        entered: switch (p.objectOrNull('entered')) {
          final e? => {for (final k in e.keys) k: e.string(k)},
          null => const {},
        },
      ),
      _Kind.conversationUpdate => TeamsConversationUpdate(
        conversation: conversation,
        id: id,
        serviceUrl: serviceUrl,
        bot: bot,
        tenant: tenant,
        conversationType: conversationType,
        timestamp: timestamp,
        from: from,
        fromAadObjectId: fromAadObjectId,
        channel: channel,
        team: team,
        added: _users(p, 'added'),
        removed: _users(p, 'removed'),
      ),
      _Kind.installationUpdate => TeamsInstallationUpdate(
        conversation: conversation,
        id: id,
        serviceUrl: serviceUrl,
        bot: bot,
        tenant: tenant,
        conversationType: conversationType,
        timestamp: timestamp,
        from: from,
        fromAadObjectId: fromAadObjectId,
        channel: channel,
        team: team,
        action: switch (p.stringOrNull('action')) {
          final a? => _required(InstallationAction.parse(a), 'action'),
          null => null,
        },
      ),
    };
  }
}

/// The version every projection this module writes carries. A change to
/// what a case records is a new version, read by a reader that knows it.
const teamsProjectionVersion = 1;

const _version = 'projection';
const _kindKey = 'kind';

const _commonKeys = {
  _version,
  _kindKey,
  'conversation',
  'id',
  'serviceUrl',
  'bot',
  'tenant',
  'conversationType',
  'timestamp',
  'from',
  'fromAadObjectId',
  'channel',
  'team',
};

/// The cases, as a projection names them, with the fields each adds.
enum _Kind {
  message('message', {'text', 'mentions', 'quote', 'replyTo', 'attachments'}),
  messageUpdate('messageUpdate', {'text', 'mentions', 'channelEventType'}),
  messageDelete('messageDelete', {'channelEventType'}),
  cardAction('cardAction', {'card', 'verb', 'trajectory'}),
  messageActionOpen('messageActionOpen', {'command', 'message'}),
  messageActionSubmit('messageActionSubmit', {'command', 'message', 'entered'}),
  conversationUpdate('conversationUpdate', {'added', 'removed'}),
  installationUpdate('installationUpdate', {'action'});

  const _Kind(this.asRecorded, this.ownKeys);

  final String asRecorded;
  final Set<String> ownKeys;

  static final _byRecorded = {for (final k in values) k.asRecorded: k};

  static _Kind? parse(String s) => _byRecorded[s];
}

T _required<T extends Object>(T? value, String field) =>
    value ?? (throw FormatException('$field is not in its form'));

TeamsUserId? _userOrNull(String? s, String field) =>
    s == null ? null : _required(TeamsUserId.parse(s), field);

List<TeamsUserId> _users(JsonObject p, String field) => [
  for (final s in p.stringsOrNull(field) ?? const <String>[])
    _required(TeamsUserId.parse(s), field),
];

TeamsMessageAction _command(JsonObject p) =>
    _required(TeamsMessageAction.parse(p.string('command')), 'command');

void _onlyKeys(JsonObject o, Set<String> allowed, String what) {
  for (final k in o.keys) {
    if (!allowed.contains(k)) throw FormatException('a field no $what has', k);
  }
}

/// A Teams user's id on a trajectory. To a mission everyone but the agent
/// is a user, another bot included, so both have an id, in lower case:
///
/// - a person, `teams:<tenant>/<Entra object id>`, from [entra];
/// - a bot, which Teams names by its channel id `28:<app id>` and no Entra
///   user, `teams:<tenant>/bot:<app id>`. An Entra object id is a GUID and
///   never has a colon, so the two can't be read as each other.
///
/// A person's channel id, `29:…`, is not enough on its own: it names them
/// only to this bot, so it isn't the id they have everywhere else. Null
/// when there is no [tenant], or no id of either kind.
ActorId? teamsActor(String? tenant, {TeamsUserId? user, EntraObjectId? entra}) {
  final t = tenant?.toLowerCase();
  if (t == null) return null;
  if (entra != null) return ActorId.parse('teams:$t/${entra.value}');
  if (user case final u? when u.isBot) {
    return _botActor(t, u.value.substring(3));
  }
  return null;
}

/// [bot]'s id on a trajectory in [tenant], as [teamsActor] names a bot.
ActorId? teamsBotActor(String? tenant, BotAppId bot) {
  final t = tenant?.toLowerCase();
  if (t == null) return null;
  return _botActor(t, bot.value);
}

ActorId? _botActor(String tenant, String appId) =>
    ActorId.parse('teams:$tenant/bot:${appId.toLowerCase()}');

/// What a Teams Reply quotes, read from its `quotedReply` entity: the shape
/// seen in every recorded reply so far, in a one-to-one chat and a group
/// chat alike. Teams gives the quoted message's author only as a channel id
/// and a display name, never an Entra object id.
final class TeamsQuote {
  const TeamsQuote({
    required this.messageId,
    required this.senderId,
    this.senderName,
    this.preview,
  });

  factory TeamsQuote._fromProjection(JsonObject q) {
    _onlyKeys(q, const {
      'messageId',
      'senderId',
      'senderName',
      'preview',
    }, 'quote');
    return TeamsQuote(
      messageId: q.string('messageId'),
      senderId: _required(TeamsUserId.parse(q.string('senderId')), 'senderId'),
      senderName: q.stringOrNull('senderName'),
      preview: q.stringOrNull('preview'),
    );
  }

  /// The quoted message's id, in the same conversation as the reply.
  final String messageId;

  /// Its author's channel id: `28:<app id>` for a bot, `29:…` for a person.
  final TeamsUserId senderId;

  /// Its author's display name, as Teams showed it.
  final String? senderName;

  /// Teams' shortened copy of the quoted text.
  final String? preview;

  Map<String, Object?> get _projection => {
    'messageId': messageId,
    'senderId': senderId.value,
    'senderName': ?senderName,
    'preview': ?preview,
  };
}

/// Someone @-mentioned in a message: who, and the name Teams showed.
final class TeamsMention {
  const TeamsMention({required this.id, this.name});

  factory TeamsMention._fromProjection(JsonObject m) {
    _onlyKeys(m, const {'id', 'name'}, 'mention');
    return TeamsMention(
      id: _required(TeamsUserId.parse(m.string('id')), 'mention id'),
      name: m.stringOrNull('name'),
    );
  }

  /// Their channel account id: `28:<app id>` for a bot, `29:…` for a person.
  final TeamsUserId id;

  /// The name the mention showed.
  final String? name;

  Map<String, Object?> get _projection => {'id': id.value, 'name': ?name};
}

/// That a message carried a file or card: its type and name, and nothing
/// that says where it lives. An address can carry the grant to read what
/// is there, in its query or in its path (a sharing link's token), so none
/// is recorded until something needs one and its shape has been measured.
final class TeamsAttachmentReference {
  const TeamsAttachmentReference({required this.contentType, this.name});

  factory TeamsAttachmentReference._fromProjection(JsonObject a) {
    _onlyKeys(a, const {'contentType', 'name'}, 'attachment');
    return TeamsAttachmentReference(
      contentType: a.string('contentType'),
      name: a.stringOrNull('name'),
    );
  }

  /// Its media type, as Teams names it.
  final String contentType;

  /// Its file name, when it has one.
  final String? name;

  Map<String, Object?> get _projection => {
    'contentType': contentType,
    'name': ?name,
  };
}

/// A `message`: someone, a person or a bot, sent words.
final class TeamsMessage extends TeamsEvent {
  const TeamsMessage({
    required super.conversation,
    required super.id,
    required super.serviceUrl,
    super.tenant,
    super.conversationType,
    super.timestamp,
    super.from,
    super.fromAadObjectId,
    required super.bot,
    super.channel,
    super.team,
    this.text,
    this.mentions = const [],
    this.quote,
    this.replyTo,
    this.attachments = const [],
  });

  /// As Teams sent it, `<at>` mentions and quote tags included.
  final String? text;

  /// Who it @-mentions, in the order Teams gave them.
  final List<TeamsMention> mentions;

  /// What this message quotes, when it is a Reply. In a chat a Reply has
  /// no [replyTo], so this is the only place Teams says what it is about.
  final TeamsQuote? quote;

  /// In a channel, the message this one replies under.
  final String? replyTo;

  /// What it carried besides its words, by reference.
  final List<TeamsAttachmentReference> attachments;

  @override
  _Kind get _kind => _Kind.message;

  @override
  Map<String, Object?> get _own => {
    'text': text,
    'mentions': [for (final m in mentions) m._projection],
    'quote': quote?._projection,
    'replyTo': replyTo,
    'attachments': [for (final a in attachments) a._projection],
  };
}

/// A `messageUpdate`: a message was changed.
final class TeamsMessageUpdate extends TeamsEvent {
  const TeamsMessageUpdate({
    required super.conversation,
    required super.id,
    required super.serviceUrl,
    super.tenant,
    super.conversationType,
    super.timestamp,
    super.from,
    super.fromAadObjectId,
    required super.bot,
    super.channel,
    super.team,
    this.text,
    this.mentions = const [],
    this.channelEventType,
  });

  final String? text;
  final List<TeamsMention> mentions;

  /// Teams' own name for the change, `channelData.eventType`, such as
  /// `editMessage`, when Teams gives it.
  final String? channelEventType;

  @override
  _Kind get _kind => _Kind.messageUpdate;

  @override
  Map<String, Object?> get _own => {
    'text': text,
    'mentions': [for (final m in mentions) m._projection],
    'channelEventType': channelEventType,
  };
}

/// A `messageDelete`: a message was deleted.
final class TeamsMessageDelete extends TeamsEvent {
  const TeamsMessageDelete({
    required super.conversation,
    required super.id,
    required super.serviceUrl,
    super.tenant,
    super.conversationType,
    super.timestamp,
    super.from,
    super.fromAadObjectId,
    required super.bot,
    super.channel,
    super.team,
    this.channelEventType,
  });

  /// Teams' own name for the change, `channelData.eventType`, such as
  /// `softDeleteMessage`, when Teams gives it.
  final String? channelEventType;

  @override
  _Kind get _kind => _Kind.messageDelete;

  @override
  Map<String, Object?> get _own => {'channelEventType': channelEventType};
}

/// An `invoke` named `adaptiveCard/action`: an action on a card was pressed.
/// Of what the card sent back, only the verb and the trajectory a Close
/// names are kept.
final class TeamsCardAction extends TeamsEvent {
  const TeamsCardAction({
    required super.conversation,
    required super.id,
    required super.serviceUrl,
    super.tenant,
    super.conversationType,
    super.timestamp,
    super.from,
    super.fromAadObjectId,
    required super.bot,
    super.channel,
    super.team,
    this.card,
    this.verb,
    this.trajectory,
  });

  /// The card's own activity id.
  final String? card;

  /// The action's verb; null for one our cards don't send.
  final CardActionVerb? verb;

  /// The trajectory a reply's Close names in its data, when it names one.
  /// The Teams client sends the data back and could send anything, so this
  /// is only a claim: the docking station closes it only while it is the
  /// trajectory open where the press came from.
  final TrajectoryId? trajectory;

  @override
  _Kind get _kind => _Kind.cardAction;

  @override
  Map<String, Object?> get _own => {
    'card': card,
    'verb': verb?.asSent,
    'trajectory': trajectory?.hex,
  };
}

/// The verbs our cards send, read once from the string Teams carries.
enum CardActionVerb {
  approve('approve'),
  notYet('notyet'),

  /// Reopens the choice on a card, and writes nothing.
  edit('edit'),

  /// Asks to close the trajectory the card stands in.
  close('close');

  const CardActionVerb(this.asSent);

  /// The verb as the card sends it.
  final String asSent;

  static final _byAsSent = {for (final v in values) v.asSent: v};

  /// The verb [asSent] names, or null for one our cards don't send.
  static CardActionVerb? parse(String? asSent) => _byAsSent[asSent];
}

/// The message actions the app's manifest declares, read once from the
/// command id Teams carries.
enum TeamsMessageAction {
  /// Opens a conversation's call settings: the model, effort and so on its
  /// agent runs with.
  callSettings(callSettingsCommandId);

  const TeamsMessageAction(this.commandId);

  /// The command's id in the manifest.
  final String commandId;

  static final _byCommandId = {for (final a in values) a.commandId: a};

  /// The action [commandId] names, or null for one the manifest doesn't
  /// declare.
  static TeamsMessageAction? parse(String? commandId) =>
      _byCommandId[commandId];
}

/// The manifest id of the message action that opens a conversation's call
/// settings.
const callSettingsCommandId = 'callSettings';

/// A `composeExtension/fetchTask`: someone chose a message action from a
/// message's "..." menu, and its dialog is to open.
final class TeamsMessageActionOpen extends TeamsEvent {
  const TeamsMessageActionOpen({
    required super.conversation,
    required super.id,
    required super.serviceUrl,
    super.tenant,
    super.conversationType,
    super.timestamp,
    super.from,
    super.fromAadObjectId,
    required super.bot,
    super.channel,
    super.team,
    required this.command,
    this.message,
  });

  final TeamsMessageAction command;

  /// The id, in [conversation], of the message whose menu it was opened
  /// from.
  final String? message;

  @override
  _Kind get _kind => _Kind.messageActionOpen;

  @override
  Map<String, Object?> get _own => {
    'command': command.commandId,
    'message': message,
  };
}

/// A `composeExtension/submitAction`: someone filled in the dialog a
/// message action opened, and submitted it. What they entered exists
/// nowhere but this request, so it is kept: the text of each input, by its
/// id.
final class TeamsMessageActionSubmit extends TeamsEvent {
  const TeamsMessageActionSubmit({
    required super.conversation,
    required super.id,
    required super.serviceUrl,
    super.tenant,
    super.conversationType,
    super.timestamp,
    super.from,
    super.fromAadObjectId,
    required super.bot,
    super.channel,
    super.team,
    required this.command,
    this.message,
    this.entered = const {},
  });

  final TeamsMessageAction command;

  /// The id, in [conversation], of the message whose menu it was opened
  /// from.
  final String? message;

  /// What was entered, as text, by input id. An input whose value is not
  /// text is left out, so nothing but what a person typed or chose is kept.
  final Map<String, String> entered;

  /// The message whose menu it was opened from, by where it was said.
  TeamsMessageRef? get messageRef => switch (message) {
    final m? => TeamsMessageRef.of(conversation, m),
    null => null,
  };

  @override
  _Kind get _kind => _Kind.messageActionSubmit;

  @override
  Map<String, Object?> get _own => {
    'command': command.commandId,
    'message': message,
    'entered': entered,
  };
}

/// A `conversationUpdate`. Only who was added or removed is read from it:
/// people, or the bot.
final class TeamsConversationUpdate extends TeamsEvent {
  const TeamsConversationUpdate({
    required super.conversation,
    required super.id,
    required super.serviceUrl,
    super.tenant,
    super.conversationType,
    super.timestamp,
    super.from,
    super.fromAadObjectId,
    required super.bot,
    super.channel,
    super.team,
    this.added = const [],
    this.removed = const [],
  });

  /// The channel account ids of those added; the bot's own is
  /// `28:<`[bot]`>`.
  final List<TeamsUserId> added;
  final List<TeamsUserId> removed;

  @override
  _Kind get _kind => _Kind.conversationUpdate;

  @override
  Map<String, Object?> get _own => {
    'added': [for (final u in added) u.value],
    'removed': [for (final u in removed) u.value],
  };
}

/// An `installationUpdate`: the app was installed in, or removed from, a
/// conversation.
final class TeamsInstallationUpdate extends TeamsEvent {
  const TeamsInstallationUpdate({
    required super.conversation,
    required super.id,
    required super.serviceUrl,
    super.tenant,
    super.conversationType,
    super.timestamp,
    super.from,
    super.fromAadObjectId,
    required super.bot,
    super.channel,
    super.team,
    this.action,
  });

  /// Installed or removed; null for an action Teams named otherwise.
  final InstallationAction? action;

  @override
  _Kind get _kind => _Kind.installationUpdate;

  @override
  Map<String, Object?> get _own => {'action': action?.asSent};
}

/// What an `installationUpdate` says happened to the app.
enum InstallationAction {
  add('add'),
  remove('remove');

  const InstallationAction(this.asSent);

  final String asSent;

  static final _byAsSent = {for (final a in values) a.asSent: a};

  static InstallationAction? parse(String? asSent) => _byAsSent[asSent];
}
