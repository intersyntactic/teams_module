import 'package:checked_json/checked_json.dart';
import 'package:is_shapes/is_shapes.dart';

/// One thing that happened in Teams, checked by the gate and read into what
/// it is: something said, edited or deleted, a card pressed, members or an
/// install changed, or another invoke the gate was told to take.
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

  /// Who sent it: `teams:<tenant>/<Entra object id>`, both GUIDs in lower
  /// case. Null when Teams named no tenant or no Entra user, as for another
  /// bot.
  ActorId? get actor {
    final tenant = this.tenant;
    final user = fromAadObjectId;
    if (tenant == null || user == null) return null;
    return ActorId.parse('teams:${tenant.toLowerCase()}/${user.toLowerCase()}');
  }
}

/// A message someone sent.
final class TeamsSaid extends TeamsEvent {
  const TeamsSaid({
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

/// A message someone edited.
final class TeamsEdited extends TeamsEvent {
  const TeamsEdited({
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

/// A message someone deleted.
final class TeamsDeleted extends TeamsEvent {
  const TeamsDeleted({
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

/// A press on a card's action.
final class TeamsPressed extends TeamsEvent {
  const TeamsPressed({
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

/// An invoke other than a card press, one the gate was told to take.
final class TeamsInvoked extends TeamsEvent {
  const TeamsInvoked({
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

/// People, or the bot, added to or removed from a conversation.
final class TeamsMembersChanged extends TeamsEvent {
  const TeamsMembersChanged({
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

/// The app installed in, or removed from, a conversation.
final class TeamsInstallChanged extends TeamsEvent {
  const TeamsInstallChanged({
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
