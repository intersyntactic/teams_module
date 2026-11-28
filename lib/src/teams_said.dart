import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart';

import 'teams_ids.dart';
import 'teams_event.dart';

/// [message] as a [UserSaid]. A Reply carries what it quotes, and may then
/// have no words of its own: an @-mention of the bot on a quoted message
/// says "look at this". Null when Teams named no sender, or the message has
/// no words and quotes nothing.
///
/// [entraOf] names a quoted author from what the logbook has said so far;
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

/// What [message] quotes, its author named when the logbook knows them and
/// otherwise by the name Teams showed, with Teams' preview of its text: the
/// only words of it the trajectory has when the quoted message never
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
