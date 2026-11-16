/// teams-reply: the renderer that draws a Teams reply's body from recorded
/// entries. Pure: entries in, a body or a refusal out, with no clock, no
/// randomness and no I/O, so the same entries always draw the same body.
///
/// It is named by its `RendererId`, the sha256 of this package's archive as
/// published on pub.dev (https://github.com/enspyrco/intersyntactic/issues/1147).
/// It imports nothing but the SDK, so that archive holds every line that
/// can change what is drawn: no version resolved at build time can. The
/// pure list (https://github.com/enspyrco/intersyntactic/issues/1046) also
/// admits checked_json; this does without it.
///
/// What it draws today: the reply to someone, from the one closing turn
/// entry that holds a `ReplyText` node. Its bytes are pinned by agent_loop's
/// `test/reply_text_envelope_test.dart`
/// (https://github.com/intersyntactic/agent_loop/pull/11); this reads only
/// `shape` and `text`, and ignores the rest. Streaming sends, which name
/// every `ReplyChunk` in order, come when the chunk's kind and bytes are
/// fixed. Until then any other entry is refused.
library;

import 'dart:convert';
import 'dart:typed_data';

/// One recorded entry, as the render runner hands it on: its [kind], and
/// its [body] after the `<kind>\n<follows>\n` header.
final class Entry {
  const Entry(this.kind, this.body);

  final String kind;
  final Uint8List body;
}

/// What the renderer drew.
sealed class RenderOutcome {
  const RenderOutcome();
}

/// The HTTP body to send, exactly: a Bot Framework activity, as JSON.
final class RenderedBody extends RenderOutcome {
  const RenderedBody(this.text);

  final String text;
}

/// Nothing is sent, because [why].
final class RenderRefused extends RenderOutcome {
  const RenderRefused(this.why);

  final String why;
}

/// The body of a Teams reply drawn from [entries], in the order the send
/// names them.
RenderOutcome teamsReply(List<Entry> entries) {
  if (entries case [Entry(kind: 'turn', :final body)]) {
    final Object? turn;
    try {
      turn = jsonDecode(utf8.decode(body));
    } on FormatException catch (e) {
      return RenderRefused('the turn is not JSON: ${e.message}');
    }
    return switch (turn) {
      {'node': {'shape': 'ReplyText', 'text': final String text}} =>
        RenderedBody(jsonEncode({'type': 'message', 'text': text})),
      {'node': {'shape': 'ReplyText'}} => const RenderRefused(
        'the ReplyText holds no text',
      ),
      {'node': {'shape': final String shape}} => RenderRefused(
        'a $shape turn draws no Teams reply',
      ),
      _ => const RenderRefused('the turn holds no node'),
    };
  }
  return RenderRefused(
    'a Teams reply is drawn from one turn, not '
    '${entries.isEmpty ? 'none' : entries.map((e) => e.kind).join(', ')}',
  );
}
