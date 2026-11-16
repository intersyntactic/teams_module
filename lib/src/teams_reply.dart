/// teams-reply: the renderer that draws a Teams post's body from the record
/// (Nick, 16 Nov 13:49: the airlock doesn't call renderers; a renderer
/// follows the record).
///
/// It follows the record for `decided` entries, and for each one naming it,
/// still unanswered,
/// reads the entries the post draws from, renders the body, and records it
/// as a `rendered` entry following the `Decided`. Each post is a chain of
/// its own (Decided, then Rendered, then Returned), so the writer's tip
/// check refuses a second Rendered for one Decided: two renderers racing,
/// or one restarting, cannot answer a post twice. On a restart it reads the
/// record from the start, asks each Decided's tip, and renders only those
/// still at their tip; it keeps no state of its own.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'journal_reader.dart';
import 'record_event.dart';

/// What [TeamsReply] does with one post's entries: a body to send, or a
/// refusal, which reaches no one.
sealed class Rendering {
  const Rendering();
}

/// The body to send, exactly.
final class RenderedBody extends Rendering {
  const RenderedBody(this.body);

  final String body;
}

/// Nothing is sent, because [why].
final class RenderRefused extends Rendering {
  const RenderRefused(this.why);

  final String why;
}

/// Records [body] as kind [kind] following [follows].
typedef WriteEntry = Future<RecordAnswer> Function(
  String kind,
  String follows,
  Uint8List body,
);

/// The renderer loop: everything it touches is handed in, so it runs the
/// same against the record and against a test's.
final class TeamsReply {
  TeamsReply({
    required this.follow,
    required this.tip,
    required this.get,
    required this.write,
    required this.drawsFrom,
    required this.render,
    required this.source,
    this.dryRun = false,
    this.log = _silent,
  });

  /// Follows the record from the start.
  final Stream<Followed> Function(Iterable<String> kinds) follow;
  final Future<String> Function(String entry) tip;
  final Future<Got> Function(String entry) get;
  final WriteEntry write;

  /// The entries a `decided` entry's post draws from, in order, if it names
  /// this renderer; null for any other post.
  final List<String>? Function(FollowedEntry decided) drawsFrom;

  /// The body drawn from the post's entries, which are already read. No
  /// clock, no randomness: the same entries render the same body.
  final Rendering Function(List<FollowedEntry> entries) render;

  /// The source FileSetId this renderer was compiled from. The writer
  /// stamps entries with its own code, never the sender's, so this is the
  /// only trace of which teams-reply rendered a post, and readers take it as
  /// a claim.
  final String source;

  /// Renders and logs what it would write, and writes nothing: a deploy
  /// rehearses against the live record, which keeps whatever is added.
  final bool dryRun;

  final void Function(String line) log;

  static void _silent(String _) {}

  /// Follows the record until it ends, answering each post naming it.
  Future<void> run() async {
    await for (final followed in follow(const ['decided'])) {
      switch (followed) {
        case CaughtUp(:final head):
          log('teams-reply: caught up at ${head ?? '-'}');
        case final FollowedEntry decided:
          await answer(decided);
      }
    }
  }

  /// Answers [decided] if it names this renderer and is still unanswered.
  Future<void> answer(FollowedEntry decided) async {
    final from = drawsFrom(decided);
    if (from == null) return;
    // A read that fails says nothing about the post: it is left unanswered,
    // never refused, since a refusal is kept for good. The next start asks
    // its tip again.
    final Rendering rendering;
    try {
      if (await tip(decided.hash) != decided.hash) return;
      rendering = await _render(from);
    } on Exception catch (e) {
      log('teams-reply: left ${decided.hash} unanswered: $e');
      return;
    }
    final body = renderedEntry(decided.hash, rendering, source);
    final what = switch (rendering) {
      RenderedBody(:final body) => 'a body of ${utf8.encode(body).length} B',
      RenderRefused(:final why) => 'a refusal ($why)',
    };
    if (dryRun) {
      log('teams-reply: would render ${decided.hash} as $what');
      return;
    }
    final answer = await write('rendered', decided.hash, body);
    log(switch (answer) {
      Recorded(:final entry) =>
        'teams-reply: rendered ${decided.hash} as $what in $entry',
      RecordRefused(:final why) when why.startsWith('not-tip') =>
        'teams-reply: ${decided.hash} already answered',
      RecordRefused(:final why) =>
        'teams-reply: refused rendering ${decided.hash}: $why',
      RecordFailed(:final why) =>
        'teams-reply: failed rendering ${decided.hash}: $why',
      RecordUnanswered(:final why) =>
        'teams-reply: no answer rendering ${decided.hash}: $why',
    });
  }

  Future<Rendering> _render(List<String> from) async {
    final entries = <FollowedEntry>[];
    for (final hash in from) {
      switch (await get(hash)) {
        case GotEntry(:final entry):
          entries.add(entry);
        case GotNone():
          return RenderRefused('entry $hash was never recorded');
        case GotUnreadable(:final why):
          return RenderRefused('entry $hash is $why');
      }
    }
    return render(entries);
  }
}

/// The `rendered` entry's body for [decided]: the post's body or the
/// refusal's reason, and the [source] that rendered it.
///
/// A stand-in until is_airlock_api 0.5.0 gives Rendered its wire form; the
/// airlock reads it, so the form is the contract's to say.
Uint8List renderedEntry(String decided, Rendering rendering, String source) =>
    utf8.encode(
      jsonEncode({
        'decided': decided,
        ...switch (rendering) {
          RenderedBody(:final body) => {'body': body},
          RenderRefused(:final why) => {'refused': why},
        },
        'source': source,
      }),
    );
