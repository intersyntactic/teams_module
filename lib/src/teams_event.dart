import 'package:checked_json/checked_json.dart';
import 'package:is_shapes/is_shapes.dart';

import 'teams_ids.dart';

/// Teams' record of one activity, checked by the gate. Each case is named
/// for Teams' own activity, since it is Teams' account of what happened, not
/// a reading of it: Teams says nothing, a user does, and saying is what the
/// translator reads from it.
///
/// It carries content: a person's words and what they submitted on a card
/// exist nowhere but the request that brought them, so they come here, not
/// as a pointer to fetch them by.
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
  /// so [ref] is what names it.
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

  /// The quoted message's id, in the same conversation as the reply.
  final String messageId;

  /// Its author's channel id: `28:<app id>` for a bot, `29:…` for a person.
  final TeamsUserId senderId;

  /// Its author's display name, as Teams showed it.
  final String? senderName;

  /// Teams' shortened copy of the quoted text.
  final String? preview;
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
    this.entities,
    this.replyTo,
  });

  /// As Teams sent it, `<at>` mentions and quote tags included.
  final String? text;

  /// As they came: @-mentions, and the quoted-reply entity that says which
  /// earlier message a reply quotes, which [quote] reads.
  final List<JsonObject>? entities;

  /// In a channel, the message this one replies under.
  final String? replyTo;

  /// What this message quotes, when it is a Reply: the first `quotedReply`
  /// entity that names both a message and its author. In a chat a Reply has
  /// no [replyTo], so this is the only place Teams says what it is about.
  TeamsQuote? get quote {
    for (final e in entities ?? const <JsonObject>[]) {
      // wire-ok: Teams' entity type, an open set; only this one is read.
      if (e.stringOrNull('type') != 'quotedReply') continue;
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
    this.entities,
    this.channelEventType,
  });

  final String? text;
  final List<JsonObject>? entities;

  /// Teams' own name for the change, `channelData.eventType`, such as
  /// `editMessage`, when Teams gives it.
  final String? channelEventType;
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
}

/// An `invoke` named `adaptiveCard/action`: an action on a card was pressed.
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
    this.value,
  });

  /// The card's own activity id.
  final String? card;

  /// What was submitted: the action's verb and any inputs.
  final JsonObject? value;

  /// The action's verb, when it is one our cards send.
  CardActionVerb? get verb =>
      CardActionVerb.parse(value?.objectOrNull('action')?.stringOrNull('verb'));
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

/// A `composeExtension/submitAction`: someone filled in the dialog a
/// message action opened from a message's "..." menu, and submitted it.
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
    this.command,
    this.message,
    this.data,
  });

  /// The command's id in the manifest, such as [callSettingsCommandId].
  final String? command;

  /// The id, in [conversation], of the message whose menu it was opened
  /// from.
  final String? message;

  /// The dialog's submitted values, by input id.
  final JsonObject? data;

  /// The message whose menu it was opened from, by where it was said.
  TeamsMessageRef? get messageRef => switch (message) {
    final m? => TeamsMessageRef.of(conversation, m),
    null => null,
  };
}

/// The manifest id of the message action that opens a conversation's call
/// settings: the model, effort and so on its agent runs with.
const callSettingsCommandId = 'callSettings';

/// Any other `invoke` the gate was told to take.
final class TeamsInvoke extends TeamsEvent {
  const TeamsInvoke({
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
    this.name,
    this.value,
  });

  final String? name;
  final JsonObject? value;
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

  /// `add` or `remove`.
  final String? action;
}
