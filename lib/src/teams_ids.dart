import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart';

/// A Teams message by where it was said: its conversation, and its id there.
/// Teams makes a message id unique only within its conversation (it is the
/// millisecond the message was sent, in digits), so one alone can name two
/// messages in two chats.
///
/// On a trajectory it is a [SourceMessageId], `<conversation>|<message>`,
/// and this is the one way to that string and back: split at the last `|`,
/// so only the message id has to be free of one.
final class TeamsMessageRef {
  const TeamsMessageRef._(this.conversation, this.message);

  /// The conversation's id.
  final String conversation;

  /// The message's id within [conversation].
  final String message;

  /// The message [message] in [conversation]; null when either is empty or
  /// has whitespace, or [message] has a `|`.
  static TeamsMessageRef? of(String conversation, String message) =>
      _part.hasMatch(conversation) &&
          _part.hasMatch(message) &&
          !message.contains('|')
      ? TeamsMessageRef._(conversation, message)
      : null;

  /// The message [source] names, when it names a Teams message.
  static TeamsMessageRef? fromSource(SourceMessageId source) {
    final s = source.value;
    final bar = s.lastIndexOf('|');
    if (bar < 0) return null;
    return of(s.substring(0, bar), s.substring(bar + 1));
  }

  /// This message as a trajectory names it.
  SourceMessageId get source =>
      SourceMessageId.parse('$conversation|$message')!;

  static final _part = RegExp(r'^\S+$');

  @override
  bool operator ==(Object other) =>
      other is TeamsMessageRef &&
      other.conversation == conversation &&
      other.message == message;

  @override
  int get hashCode => Object.hash(conversation, message);

  @override
  String toString() => '$conversation|$message';
}

/// A Teams channel account id: `29:…` for a person, `28:<app id>` for a
/// bot. It names an account only to this bot, so it is not who the person
/// is anywhere else; that is their [EntraObjectId].
final class TeamsUserId {
  const TeamsUserId._(this.value);

  /// The id as Teams sent it.
  final String value;

  /// [s] as a channel account id; null unless it is `28:` or `29:` and more,
  /// with no whitespace, the only two kinds seen in a recorded body.
  static TeamsUserId? parse(String s) =>
      RegExp(r'^2[89]:\S+$').hasMatch(s) ? TeamsUserId._(s) : null;

  /// Whether this is a bot's id, `28:<app id>`.
  bool get isBot => value.startsWith('28:');

  @override
  bool operator ==(Object other) =>
      other is TeamsUserId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// A person's Entra object id: who they are across Microsoft 365, the same
/// in every chat and every app. A GUID, held in lower case.
final class EntraObjectId {
  const EntraObjectId._(this.value);

  /// The GUID, in lower case.
  final String value;

  /// [s] as an Entra object id; null unless it is a GUID, in either case.
  static EntraObjectId? parse(String s) =>
      _guid.hasMatch(s) ? EntraObjectId._(s.toLowerCase()) : null;

  @override
  bool operator ==(Object other) =>
      other is EntraObjectId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// A bot's Microsoft app id: the GUID of its Entra app registration, the
/// audience of every token sent to it, and what Teams names it by as
/// `28:<app id>`. Held in lower case.
final class BotAppId {
  const BotAppId._(this.value);

  /// The GUID, in lower case.
  final String value;

  /// [s] as a bot's app id; null unless it is a GUID, in either case.
  static BotAppId? parse(String s) =>
      _guid.hasMatch(s) ? BotAppId._(s.toLowerCase()) : null;

  /// The bot [account] names, when it is a bot's channel account id.
  static BotAppId? ofChannelAccount(TeamsUserId account) =>
      account.isBot ? parse(account.value.substring(3)) : null;

  @override
  bool operator ==(Object other) => other is BotAppId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final _guid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
