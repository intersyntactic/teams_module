/// The follower: the one program every renderer is built into (Nick, 16 Nov
/// 13:49: the airlock doesn't call renderers; a renderer follows the record).
///
/// It follows the record for `post-decided` entries, and for each one the
/// airlock allowed, naming this build's renderer, still unanswered, reads
/// the entries the post draws from, hands them to the renderer, and records
/// what it drew as a `rendered` entry following the `post-decided`. Each
/// post is a chain of its own (decided, then rendered, then returned), so
/// the writer's tip check refuses a second `rendered` for one post: two
/// followers racing, or one restarting, cannot answer a post twice. On a
/// restart it reads the record from the start, asks each post's tip, and
/// renders only those still at their tip; it keeps no state of its own.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_effects/is_effects.dart' show Outcome, Ran, Refused;

import 'journal_reader.dart';
import 'write_entry.dart';

/// The renderer this follower was built with, from `-Drenderer=<id>`: the
/// shasum of the renderer package's `lib/*.dart` (see [RendererId]). Null
/// when the build named none, or named something that is not an id, and
/// then the follower must not start: it would answer no post, or every
/// post named for a renderer it is not.
RendererId? compiledRenderer() =>
    RendererId.parse(const String.fromEnvironment('renderer'));

/// Records [body] as kind [kind] following [follows].
typedef WriteEntry = Future<RecordAnswer> Function(
  String kind,
  String follows,
  Uint8List body,
);

/// The follower loop: everything it touches is handed in, so it runs the
/// same against the record and against a test's.
final class RenderFollower {
  RenderFollower({
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

  /// What the log calls this follower, such as `teams-reply`.
  final String name;

  /// The renderer it was built with: it answers only posts naming this id,
  /// and reports it in each `rendered` entry. The writer stamps entries with
  /// its own code, never the sender's, so this is the record's only trace of
  /// which renderer drew a post, and readers take it as a claim.
  final RendererId renderer;

  /// Follows the record from the start.
  final Stream<Followed> Function(Iterable<String> kinds) follow;
  final Future<String> Function(String entry) tip;
  final Future<Got> Function(String entry) get;
  final WriteEntry write;

  /// The body drawn from the post's entries, which are already read and
  /// checked, in the order the post names them. The renderer is pure: the
  /// same entries draw the same body.
  final Outcome<String> Function(List<FollowedEntry> entries) render;

  /// Renders and logs what it would write, and writes nothing: a deploy
  /// rehearses against the live record, which keeps whatever is added.
  final bool dryRun;

  final void Function(String line) log;

  static void _silent(String _) {}

  /// Follows the record until it ends, answering each post naming it.
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
    // A read that fails says nothing about the post: it is left unanswered,
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

  /// [decided]'s id and post if this follower answers it, or null: denied,
  /// named for another renderer, or not a post's entry at all, which is
  /// logged, since the writer let it in under the kind.
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
