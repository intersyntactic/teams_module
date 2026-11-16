/// teams-reply: the follower built with this package's renderer. It follows
/// the record for posts the airlock allowed naming it, and records each
/// one's body. It holds no secret and reaches no network: only the record's
/// read socket and its writer's socket, both Unix.
///
///   JOURNAL_READ_SOCKET=/run/...sock  the record's read socket. Required.
///   JOURNAL_SOCKET=/run/...sock       the record's writer. Required unless
///                                     dry-running.
///   TEAMS_REPLY_DRY_RUN=1             render and log what would be
///                                     written, and write nothing: the
///                                     record keeps whatever is added, so
///                                     a deploy's rehearsal must add none.
///
/// Built with the renderer's id, which it reports in every `rendered`
/// entry; a build without one refuses to start. The id is the shasum of the
/// `lib/*.dart` of the renderer and of every package it imports, each path
/// under its package's name (is_shapes 0.4.5's `RendererId`). `lib/`
/// imports no package, so that is this package's files alone, under
/// `teams_reply/`. From this package's root:
///
///     dart compile exe -Drenderer=$( (cd lib && find . -type f \
///       -name '*.dart' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 \
///       | sed 's|  \./|  ./teams_reply/|') | shasum -a 256 | cut -c1-64) \
///       bin/teams_reply.dart
library;

import 'dart:io';

import 'package:render_follower/render_follower.dart';
import 'package:teams_reply/teams_reply.dart';

Future<void> main() async {
  final env = Platform.environment;
  final dryRun = env['TEAMS_REPLY_DRY_RUN'] == '1';
  final read = env['JOURNAL_READ_SOCKET'] ?? '';
  final write = env['JOURNAL_SOCKET'] ?? '';
  final renderer = compiledRenderer();
  if (renderer == null) {
    stderr.writeln('abort: built without -Drenderer=<RendererId>');
    exit(78);
  }
  if (read.isEmpty || (!dryRun && write.isEmpty)) {
    stderr.writeln(
      'abort: JOURNAL_READ_SOCKET and, unless dry-running, JOURNAL_SOCKET '
      'must be set',
    );
    exit(78);
  }

  final reader = JournalReader(read);
  final follower = RenderFollower(
    name: 'teams-reply',
    renderer: renderer,
    follow: (kinds) => reader.follow(kinds),
    tip: reader.tip,
    get: reader.get,
    write: (kind, follows, body) =>
        writeEntry(write, kind: kind, follows: follows, body: body),
    render: (entries) =>
        switch (teamsReply([for (final e in entries) Entry(e.kind, e.body)])) {
          Body(:final text) => Ran(text),
          Refusal(:final why) => Refused(why),
        },
    dryRun: dryRun,
    log: stdout.writeln,
  );
  stdout.writeln(
    'teams-reply: following $read as ${renderer.hex}'
    '${dryRun ? ', dry run' : ''}',
  );
  // However the follow ends, the service restarts it: a restart reads the
  // record from the start and answers only what is still unanswered.
  try {
    await follower.run();
    stderr.writeln('teams-reply: the record stopped the follow');
  } on Exception catch (e) {
    stderr.writeln('teams-reply: the follow failed: $e');
  }
  exit(75);
}
