import 'package:is_conversation_shapes/is_conversation_shapes.dart';
import 'package:is_shapes/is_shapes.dart';

import 'teams_authors.dart';
import 'teams_ids.dart';
import 'teams_event.dart';
import 'teams_conversation.dart';
import 'teams_post.dart';

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
  final _heard = <TurnId, TeamsMessageRef>{};

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
    final said = teamsSaid(message, entraOf: authors.entraIdOf);
    if (said == null) return null;
    return (
      joined: _serviceUrls[message.conversation] == message.serviceUrl
          ? null
          : TeamsConversation(
              id: message.conversation,
              serviceUrl: message.serviceUrl,
            ),
      said: said,
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
    final where = TeamsMessageRef.fromSource(said.source);
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
}

/// [message] as a [UserSaid]: who, where, and what. A Reply carries what it
/// quotes, and may then have no words of its own: an @-mention of the bot
/// on a quoted message says "look at this". Null when Teams named no
/// sender, or the message has no words and quotes nothing.
///
/// [entraOf] names a quoted author from what the record has said so far;
/// the sender of [message] should already be in it, so a person quoting
/// themselves is named even the first time they are heard from.
UserSaid? teamsSaid(
  TeamsMessage message, {
  required EntraObjectId? Function(TeamsUserId) entraOf,
}) {
  final author = message.actor;
  final text = _plain(message.text ?? '');
  final source = message.ref?.source;
  final quotes = switch (message.quote) {
    final q? => _quote(message, q, entraOf),
    null => null,
  };
  if (author == null || source == null) return null;
  if (text.isEmpty && quotes == null) return null;
  return UserSaid(author: author, source: source, text: text, quotes: quotes);
}

/// What [message] quotes, its author named when the record knows them and
/// otherwise by the name Teams showed, with Teams' preview of its text: the
/// only words of it the journey path has when the quoted message never
/// reached it. A quote is always of a message in the same chat.
Quote? _quote(
  TeamsMessage message,
  TeamsQuote q,
  EntraObjectId? Function(TeamsUserId) entraOf,
) {
  final quoted = TeamsMessageRef.of(message.conversation, q.messageId);
  if (quoted == null) return null;
  final actor = teamsActor(
    message.tenant,
    user: q.senderId,
    entra: entraOf(q.senderId),
  );
  return Quote(
    source: quoted.source,
    author: actor == null ? UnknownAuthor(q.senderName) : KnownAuthor(actor),
    preview: q.preview,
  );
}

/// Text without Teams' `<at>…</at>` mentions and quote tags.
String _plain(String text) => text
    .replaceAll(RegExp(r'<at>[^<]*</at>'), '')
    .replaceAll(RegExp(r'<quoted[^>]*/>'), '')
    .trim();
