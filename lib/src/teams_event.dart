import 'package:checked_json/checked_json.dart';
import 'package:is_shapes/is_shapes.dart';

/// Teams' record of one activity, checked by the gate. Each case is named
/// for Teams' own activity, since it is Teams' account of what happened, not
/// a reading of it: Teams says nothing, a user does, and saying is what the
/// interpreter reads from it.
///
/// It carries content: a person's words and what they submitted on a card
/// exist nowhere but the request that brought them, so they come here, not
/// as a pointer to fetch them by.
sealed class TeamsEvent {
  const TeamsEvent({
    required this.conversation,
    required this.id,
    required this.serviceUrl,
    this.tenant,
    this.conversationType,
    this.timestamp,
    this.from,
    this.fromAadObjectId,
    this.recipient,
  });

  /// The Entra tenant id, in lower case.
  final String? tenant;

  /// The conversation id.
  final String conversation;

  /// `personal`, `groupChat` or `channel`.
  final String? conversationType;

  /// The activity's id. Teams makes it unique only within [conversation].
  final String id;

  /// The Bot Connector endpoint for the conversation's region.
  final Uri serviceUrl;

  final String? timestamp;

  /// The channel's id for the sender.
  final String? from;

  /// The sender's Entra object id.
  final String? fromAadObjectId;

  /// The bot's id in this conversation.
  final String? recipient;

  /// Who sent it. To a journey everyone but the agent is a user, another
  /// bot included, so both have an id, in lower case:
  ///
  /// - a person, `teams:<tenant>/<Entra object id>`;
  /// - a bot, which Teams names by its channel id `28:<app id>` and no Entra
  ///   user, `teams:<tenant>/bot:<app id>`. An Entra object id is a GUID and
  ///   never has a colon, so the two can't be read as each other.
  ///
  /// The `28:` is from Microsoft's docs, not yet seen in a witnessed body,
  /// so what follows it is taken as it comes. Null when Teams named no
  /// tenant, or a sender that is neither.
  ActorId? get actor {
    final tenant = this.tenant?.toLowerCase();
    if (tenant == null) return null;
    if (fromAadObjectId case final user?) {
      return ActorId.parse('teams:$tenant/${user.toLowerCase()}');
    }
    if (from case final id? when id.startsWith('28:') && id.length > 3) {
      return ActorId.parse(
        'teams:$tenant/bot:${id.substring(3).toLowerCase()}',
      );
    }
    return null;
  }
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
    super.recipient,
    this.text,
    this.entities,
    this.replyTo,
  });

  /// As Teams sent it, `<at>` mentions and quote tags included.
  final String? text;

  /// As they came: @-mentions, and the quoted-reply entity that says which
  /// earlier message a reply quotes. Its JSON is described only in a Teams
  /// SDK blog post, not on Learn, so it is passed on unread rather than
  /// projected from a guess.
  final List<JsonObject>? entities;

  /// In a channel, the message this one replies under.
  final String? replyTo;
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
    super.recipient,
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
    super.recipient,
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
    super.recipient,
    this.card,
    this.value,
  });

  /// The card's own activity id.
  final String? card;

  /// What was submitted: the action's verb and any inputs.
  final JsonObject? value;

  /// The action's verb, such as `approve`.
  String? get verb => value?.objectOrNull('action')?.stringOrNull('verb');
}

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
    super.recipient,
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
    super.recipient,
    this.added = const [],
    this.removed = const [],
  });

  /// The channel's ids for those added; the bot's own is its [recipient].
  final List<String> added;
  final List<String> removed;
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
    super.recipient,
    this.action,
  });

  /// `add` or `remove`.
  final String? action;
}
