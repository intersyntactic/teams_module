/// The render runner: the one program every renderer is built into. It runs
/// the renderer and records what it drew (Nick, 16 Nov 13:49: the airlock
/// doesn't call renderers; a renderer follows the record).
///
/// A post is a message to a site, such as a reply in Teams. It is never
/// written to the record; what the record holds is the airlock's decision
/// about it, a `post-decided` entry, made before the post's body exists.
///
/// The runner follows the record for those decisions, and answers each one
/// that allowed the post, names this build's renderer, and is still
/// unanswered: it reads the entries the post is to be drawn from, hands
/// them to the renderer, and records what it drew as a `rendered` entry
/// following the decision. Each decision starts a chain of its own
/// (decided, then rendered, then returned), so the writer's tip check
/// refuses a second `rendered` after one decision: two runners racing, or
/// one restarting, cannot answer a decision twice. On a restart it reads
/// the record from the start, asks each decision's tip, and answers only
/// those still at their tip; it keeps no state of its own.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_effects/is_effects.dart' show Outcome, Ran, Refused;

import 'journal_reader.dart';
import 'write_entry.dart';

/// The renderer this runner was built with, from `-Drenderer=<id>`: the
/// sha256 of the renderer's archive on pub.dev (see [RendererId]). Null
/// when the build named none, or named something that is not an id, and
/// then the runner must not start: it would answer no decision, or every
/// decision naming a renderer it is not.
RendererId? compiledRenderer() =>
    RendererId.parse(const String.fromEnvironment('renderer'));

/// Records [body] as kind [kind] following [follows].
typedef WriteEntry = Future<RecordAnswer> Function(
  String kind,
  String follows,
  Uint8List body,
);

/// The runner loop: everything it touches is handed in, so it runs the
/// same against the record and against a test's.
final class RenderRunner {
  RenderRunner({
    required this.name,
    required this.renderer,
    required this.follow,
    required this.tip,
    required this.get,
    required this.write,
    required this.render,
    this.dryRun = false,
    this.log = _silent,
  });

  /// What the log calls this runner, such as `teams-reply`.
  final String name;

  /// The renderer it was built with: it answers only decisions naming this
  /// id, and reports it in each `rendered` entry, as a claim. What proves
  /// which renderer drew a body is the runner's build, which the decision
  /// records as the renderer's executable.
  final RendererId renderer;

  /// Follows the record from the start.
  final Stream<Followed> Function(Iterable<String> kinds) follow;
  final Future<String> Function(String entry) tip;
  final Future<Got> Function(String entry) get;
  final WriteEntry write;

  /// The body drawn from the entries the post names, already read and
  /// checked, in the order it names them. The renderer is pure: the same
  /// entries draw the same body.
  final Outcome<String> Function(List<FollowedEntry> entries) render;

  /// Renders and logs what it would write, and writes nothing: a deploy
  /// rehearses against the live record, which keeps whatever is added.
  final bool dryRun;

  final void Function(String line) log;

  static void _silent(String _) {}

  /// Follows the record until it ends, answering each decision naming it.
  Future<void> run() async {
    await for (final followed in follow(const [DecidedPost.kind])) {
      switch (followed) {
        case CaughtUp(:final head):
          log('$name: caught up at ${head ?? '-'}');
        case final FollowedEntry decided:
          await answer(decided);
      }
    }
  }

  /// Answers [decided] if the airlock allowed it, it names this renderer,
  /// and it is still unanswered.
  Future<void> answer(FollowedEntry decided) async {
    final ours = _ours(decided);
    if (ours == null) return;
    // A read that fails says nothing about the decision: it is left unanswered,
    // never refused, since a refusal is kept for good. The next start asks
    // its tip again.
    final Outcome<String> body;
    try {
      if (await tip(decided.hash) != decided.hash) return;
      body = await _render(ours.post.entries);
    } on Exception catch (e) {
      log('$name: left ${decided.hash} unanswered: $e');
      return;
    }
    final what = switch (body) {
      Ran(:final output) => 'a body of ${utf8.encode(output).length} B',
      Refused(:final why) => 'a refusal ($why)',
    };
    if (dryRun) {
      log('$name: would render ${decided.hash} as $what');
      return;
    }
    final entry = Rendered(
      decided: ours.id,
      renderer: renderer,
      body: body,
    ).toJson();
    final answer = await write(
      Rendered.kind,
      decided.hash,
      utf8.encode(jsonEncode(entry)),
    );
    log(switch (answer) {
      Recorded(:final entry) =>
        '$name: rendered ${decided.hash} as $what in $entry',
      RecordRefused(:final why) when why.startsWith('not-tip') =>
        '$name: ${decided.hash} already answered',
      RecordRefused(:final why) =>
        '$name: refused rendering ${decided.hash}: $why',
      RecordFailed(:final why) =>
        '$name: failed rendering ${decided.hash}: $why',
      RecordUnanswered(:final why) =>
        '$name: no answer rendering ${decided.hash}: $why',
    });
  }

  /// [decided]'s id and the post it decided, if this runner answers it, or
  /// null: denied, naming another renderer, or not a decision about a post
  /// at all, which is logged, since the writer let it in under the kind.
  ({EntryId id, Post post})? _ours(FollowedEntry decided) {
    final id = EntryId.parse(decided.hash);
    final DecidedPost read;
    try {
      if (id == null) throw FormatException('not an entry id: ${decided.hash}');
      read = DecidedPost.fromJson(jsonDecode(utf8.decode(decided.body)));
    } on FormatException catch (e) {
      log('$name: skipped ${decided.hash}: ${e.message}');
      return null;
    }
    if (read.decision is! Allow || read.renderer?.id != renderer) return null;
    return (id: id, post: read.post);
  }

  Future<Outcome<String>> _render(List<EntryId> from) async {
    final entries = <FollowedEntry>[];
    for (final id in from) {
      switch (await get(id.hex)) {
        case GotEntry(:final entry):
          entries.add(entry);
        case GotNone():
          return Refused('entry ${id.hex} was never recorded');
        case GotUnreadable(:final why):
          return Refused('entry ${id.hex} is $why');
      }
    }
    return render(entries);
  }
}
