/// teams-reply: the renderer that draws a Teams reply's body from recorded
/// entries. Pure: entries in, a body or a refusal out, with no clock, no
/// randomness and no I/O, so the same entries always draw the same body.
///
/// It is named by its `RendererId`, the shasum of this package's
/// `lib/*.dart` (https://github.com/enspyrco/intersyntactic/issues/1147).
/// That hash covers only this package's own files, so it imports nothing
/// but the SDK: a package import would let a dependency change what is
/// drawn without changing the id. The pure list
/// (https://github.com/enspyrco/intersyntactic/issues/1046) would admit
/// checked_json, but the id could not see which version ran.
///
/// What it draws today: the reply to someone, from the one closing turn
/// entry that holds a `ReplyText` node (is_conversation_shapes; agent-loop-b6
/// has not pinned its bytes yet, so this reads only `shape` and `text`, and
/// ignores the rest). Streaming posts, which name every `ReplyChunk` in
/// order, come when the chunk's kind and bytes are fixed. Until then any
/// other entry is refused.
library;

import 'dart:convert';
import 'dart:typed_data';

/// One recorded entry, as the follower hands it on: its [kind], and its
/// [body] after the `<kind>\n<follows>\n` header.
final class Entry {
  const Entry(this.kind, this.body);

  final String kind;
  final Uint8List body;
}

/// What the renderer drew.
sealed class Drawn {
  const Drawn();
}

/// The HTTP body to send, exactly: a Bot Framework activity, as JSON.
final class Body extends Drawn {
  const Body(this.text);

  final String text;
}

/// Nothing is sent, because [why].
final class Refusal extends Drawn {
  const Refusal(this.why);

  final String why;
}

/// The body of a Teams reply drawn from [entries], in the order the post
/// names them.
Drawn teamsReply(List<Entry> entries) {
  if (entries case [Entry(kind: 'turn', :final body)]) {
    final Object? turn;
    try {
      turn = jsonDecode(utf8.decode(body));
    } on FormatException catch (e) {
      return Refusal('the turn is not JSON: ${e.message}');
    }
    return switch (turn) {
      {'node': {'shape': 'ReplyText', 'text': final String text}} => Body(
        jsonEncode({'type': 'message', 'text': text}),
      ),
      {'node': {'shape': 'ReplyText'}} => const Refusal(
        'the ReplyText holds no text',
      ),
      {'node': {'shape': final String shape}} => Refusal(
        'a $shape turn draws no Teams reply',
      ),
      _ => const Refusal('the turn holds no node'),
    };
  }
  return Refusal(
    'a Teams reply is drawn from one turn, not '
    '${entries.isEmpty ? 'none' : entries.map((e) => e.kind).join(', ')}',
  );
}
