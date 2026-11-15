import 'package:is_conversation_shapes/is_conversation_shapes.dart';
import 'package:is_shapes/is_shapes.dart';

import 'teams_authors.dart';
import 'teams_event.dart';
import 'teams_conversation.dart';
import 'teams_post.dart';

/// A Teams message by where it was said: a message id is unique only within
/// its chat.
typedef _Where = ({String conversation, String message});

/// Translates between Teams and a journey path, one per path.
///
/// In: [said] turns a Teams message into a [UserSaid], for the journey path
/// to append. Out: [answer] turns the agent's [ReplyText] into a [TeamsPost],
/// for the airlock to decide. It appends and sends nothing itself.
///
/// To answer, it has to know which chat each message came from. It learns
/// that only from what the journey path delivers back, through [joined] and
/// [heard], so replaying the path after a restart rebuilds it.
///
/// To name who wrote a quoted message, it reads [authors], which every
/// message given to [said] teaches. Share one [TeamsAuthors] between every
/// chat's translator, so someone heard from in one chat is known when
/// quoted in another.
final class TeamsTranslator {
  TeamsTranslator({required this.authors});

  /// Who each Teams channel id is, as far as the record says.
  final TeamsAuthors authors;

  /// How to reach each chat joined.
  final _serviceUrls = <String, Uri>{};

  /// Where each [UserSaid] heard was said, by its id.
  final _heard = <TurnId, _Where>{};

  /// [message] as a [UserSaid], with a [TeamsConversation] to append before
  /// it when the chat is new to this journey path or Teams has moved it.
  /// A Reply carries what it quotes, and may then have no words of its own:
  /// an @-mention of the bot on a quoted message says "look at this". Null
  /// when Teams named no sender, or the message has no words and quotes
  /// nothing.
  ({TeamsConversation? joined, UserSaid said})? said(TeamsMessage message) {
    // Learnt first, so a person quoting themselves is named even when this
    // is the first the record has heard from them.
    authors.learn(message);
    final author = message.actor;
    final text = _plain(message.text ?? '');
    final source = SourceMessageId.parse(
      _source(message.conversation, message.id),
    );
    final quotes = switch (message.quote) {
      final q? => _quote(message, q),
      null => null,
    };
    if (author == null || source == null) return null;
    if (text.isEmpty && quotes == null) return null;
    return (
      joined: _serviceUrls[message.conversation] == message.serviceUrl
          ? null
          : TeamsConversation(
              id: message.conversation,
              serviceUrl: message.serviceUrl,
            ),
      said: UserSaid(
        author: author,
        source: source,
        text: text,
        quotes: quotes,
      ),
    );
  }

  /// What [message] quotes, its author named when the record knows them
  /// and otherwise by the name Teams showed. A quote is always of a message
  /// in the same chat.
  Quote? _quote(TeamsMessage message, TeamsQuote q) {
    final source = SourceMessageId.parse(
      _source(message.conversation, q.messageId),
    );
    if (source == null) return null;
    final actor = teamsActor(
      message.tenant,
      channelId: q.senderId,
      aadObjectId: authors.aadObjectIdOf(q.senderId),
    );
    return Quote(
      source: source,
      author: actor == null ? Unknown(q.senderName) : Known(actor),
    );
  }

  /// Notes how to reach [conversation].
  void joined(TeamsConversation conversation) =>
      _serviceUrls[conversation.id] = conversation.serviceUrl;

  /// Notes that [id] was [said] in a Teams chat. Anything not said by a
  /// Teams user is ignored.
  ///
  /// Throws a [StateError] for a Teams message from a chat never joined:
  /// the journey path delivers a [TeamsConversation] before any [UserSaid]
  /// from it, so that can only mean the path was put together wrong, and
  /// every reply to it would be lost.
  void heard(TurnId id, UserSaid said) {
    if (!said.author.value.startsWith('teams:')) return;
    final where = _where(said.source);
    if (where == null || !_serviceUrls.containsKey(where.conversation)) {
      throw StateError('$id was said in a Teams chat never joined');
    }
    _heard[id] = where;
  }

  /// [reply] as a post under the message it answers. Null when that message
  /// wasn't said in Teams.
  TeamsPost? answer(ReplyText reply) {
    final where = _heard[reply.answers];
    if (where == null) return null;
    return TeamsPost(
      serviceUrl: _serviceUrls[where.conversation]!,
      conversation: where.conversation,
      replyToId: where.message,
      activity: {'type': 'message', 'text': reply.text},
    );
  }

  /// A Teams message's source id: its chat, then `|` and its message id. It
  /// is split at the last `|`, so only the message id has to be free of one;
  /// Teams' are the millisecond they were sent, in digits, which is also why
  /// one alone can name two messages in two chats.
  static String _source(String conversation, String message) =>
      '$conversation|$message';

  static _Where? _where(SourceMessageId source) {
    final s = source.value;
    final bar = s.lastIndexOf('|');
    if (bar <= 0 || bar == s.length - 1) return null;
    return (conversation: s.substring(0, bar), message: s.substring(bar + 1));
  }

  /// Text without Teams' `<at>…</at>` mentions and quote tags.
  static String _plain(String text) => text
      .replaceAll(RegExp(r'<at>[^<]*</at>'), '')
      .replaceAll(RegExp(r'<quoted[^>]*/>'), '')
      .trim();
}
