import 'package:checked_json/checked_json.dart';
import 'package:is_shapes/is_shapes.dart';

/// One activity from Teams, checked by the gate and read into what it is:
/// something said, edited or deleted, a card pressed, members or an install
/// changed, or another invoke the gate was told to take.
///
/// It carries content: a person's words and what they submitted on a card
/// exist nowhere but the request that brought them, so they arrive here,
/// not as a pointer to fetch them by. [toJson] is its form on the wire,
/// and [TeamsArrival.fromJson] reads that form back.
sealed class TeamsArrival {
  const TeamsArrival({
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

  /// This activity's id. Teams makes it unique only within [conversation].
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

  /// `teams_` and the activity type in snake case, as on the wire.
  String get event;

  /// Its form on the wire.
  JsonObject toJson() => JsonObject.of({
    'event': event,
    'tenant': ?tenant,
    'conversation': conversation,
    'conversation_type': ?conversationType,
    'activity': id,
    'service_url': '$serviceUrl',
    'timestamp': ?timestamp,
    'from': ?from,
    'from_aad_object_id': ?fromAadObjectId,
    'recipient': ?recipient,
    ..._fields(),
  });

  Map<String, Object?> _fields();

  /// [json] read back from its form on the wire. Null for an event no
  /// arrival is read as.
  static TeamsArrival? fromJson(JsonObject json) {
    final conversation = json.string('conversation');
    final id = json.string('activity');
    final serviceUrl = Uri.parse(json.string('service_url'));
    final tenant = json.stringOrNull('tenant');
    final conversationType = json.stringOrNull('conversation_type');
    final timestamp = json.stringOrNull('timestamp');
    final from = json.stringOrNull('from');
    final fromAadObjectId = json.stringOrNull('from_aad_object_id');
    final recipient = json.stringOrNull('recipient');
    return switch (json.string('event')) {
      'teams_message' => TeamsSaid(
        conversation: conversation,
        id: id,
        serviceUrl: serviceUrl,
        tenant: tenant,
        conversationType: conversationType,
        timestamp: timestamp,
        from: from,
        fromAadObjectId: fromAadObjectId,
        recipient: recipient,
        text: json.stringOrNull('text'),
        entities: json.objectsOrNull('entities'),
        replyTo: json.stringOrNull('reply_to'),
      ),
      'teams_message_update' => TeamsEdited(
        conversation: conversation,
        id: id,
        serviceUrl: serviceUrl,
        tenant: tenant,
        conversationType: conversationType,
        timestamp: timestamp,
        from: from,
        fromAadObjectId: fromAadObjectId,
        recipient: recipient,
        text: json.stringOrNull('text'),
        entities: json.objectsOrNull('entities'),
        eventType: json.stringOrNull('event_type'),
      ),
      'teams_message_delete' => TeamsDeleted(
        conversation: conversation,
        id: id,
        serviceUrl: serviceUrl,
        tenant: tenant,
        conversationType: conversationType,
        timestamp: timestamp,
        from: from,
        fromAadObjectId: fromAadObjectId,
        recipient: recipient,
        eventType: json.stringOrNull('event_type'),
      ),
      'teams_card_action' => TeamsPressed(
        conversation: conversation,
        id: id,
        serviceUrl: serviceUrl,
        tenant: tenant,
        conversationType: conversationType,
        timestamp: timestamp,
        from: from,
        fromAadObjectId: fromAadObjectId,
        recipient: recipient,
        card: json.stringOrNull('reply_to'),
        value: json.objectOrNull('value'),
      ),
      'teams_invoke' => TeamsInvoked(
        conversation: conversation,
        id: id,
        serviceUrl: serviceUrl,
        tenant: tenant,
        conversationType: conversationType,
        timestamp: timestamp,
        from: from,
        fromAadObjectId: fromAadObjectId,
        recipient: recipient,
        name: json.stringOrNull('name'),
        value: json.objectOrNull('value'),
      ),
      'teams_conversation_update' => TeamsMembersChanged(
        conversation: conversation,
        id: id,
        serviceUrl: serviceUrl,
        tenant: tenant,
        conversationType: conversationType,
        timestamp: timestamp,
        from: from,
        fromAadObjectId: fromAadObjectId,
        recipient: recipient,
        added: json.stringsOrNull('members_added') ?? const [],
        removed: json.stringsOrNull('members_removed') ?? const [],
      ),
      'teams_installation_update' => TeamsInstallChanged(
        conversation: conversation,
        id: id,
        serviceUrl: serviceUrl,
        tenant: tenant,
        conversationType: conversationType,
        timestamp: timestamp,
        from: from,
        fromAadObjectId: fromAadObjectId,
        recipient: recipient,
        action: json.stringOrNull('action'),
      ),
      _ => null,
    };
  }
}

/// A message someone sent.
final class TeamsSaid extends TeamsArrival {
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

  @override
  String get event => 'teams_message';

  @override
  Map<String, Object?> _fields() => {
    'reply_to': ?replyTo,
    'text': ?text,
    'entities': ?entities,
  };
}

/// A message someone edited.
final class TeamsEdited extends TeamsArrival {
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
    this.eventType,
  });

  final String? text;
  final List<JsonObject>? entities;

  /// `channelData.eventType`, such as `editMessage`, when Teams gives it.
  final String? eventType;

  @override
  String get event => 'teams_message_update';

  @override
  Map<String, Object?> _fields() => {
    'text': ?text,
    'entities': ?entities,
    'event_type': ?eventType,
  };
}

/// A message someone deleted.
final class TeamsDeleted extends TeamsArrival {
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
    this.eventType,
  });

  /// `channelData.eventType`, such as `softDeleteMessage`, when Teams gives
  /// it.
  final String? eventType;

  @override
  String get event => 'teams_message_delete';

  @override
  Map<String, Object?> _fields() => {'event_type': ?eventType};
}

/// A press on a card's action.
final class TeamsPressed extends TeamsArrival {
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

  @override
  String get event => 'teams_card_action';

  @override
  Map<String, Object?> _fields() => {
    'reply_to': ?card,
    'value': ?value,
    'name': 'adaptiveCard/action',
  };
}

/// An invoke other than a card press, one the gate was told to take.
final class TeamsInvoked extends TeamsArrival {
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

  @override
  String get event => 'teams_invoke';

  @override
  Map<String, Object?> _fields() => {'value': ?value, 'name': ?name};
}

/// People, or the bot, added to or removed from a conversation.
final class TeamsMembersChanged extends TeamsArrival {
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

  @override
  String get event => 'teams_conversation_update';

  @override
  Map<String, Object?> _fields() => {
    if (added.isNotEmpty) 'members_added': added,
    if (removed.isNotEmpty) 'members_removed': removed,
  };
}

/// The app installed in, or removed from, a conversation.
final class TeamsInstallChanged extends TeamsArrival {
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

  @override
  String get event => 'teams_installation_update';

  @override
  Map<String, Object?> _fields() => {'action': ?action};
}
