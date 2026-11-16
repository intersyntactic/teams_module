/// teams-reply: follows the record for posts naming it, and records each
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
/// Built with `dart compile exe -Dteams_reply.source=<FileSetId>`: the
/// source it was compiled from, recorded in every `rendered` entry. A build
/// without one refuses to start.
library;

import 'dart:io';

import 'package:is_teams_module/is_teams_module.dart';

const _source = String.fromEnvironment('teams_reply.source');

Future<void> main() async {
  final env = Platform.environment;
  final dryRun = env['TEAMS_REPLY_DRY_RUN'] == '1';
  final read = env['JOURNAL_READ_SOCKET'] ?? '';
  final write = env['JOURNAL_SOCKET'] ?? '';
  if (_source.isEmpty) {
    stderr.writeln('abort: built without -Dteams_reply.source');
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
  final reply = TeamsReply(
    follow: (kinds) => reader.follow(kinds),
    tip: reader.tip,
    get: reader.get,
    write: (kind, follows, body) =>
        writeEntry(write, kind: kind, follows: follows, body: body),
    // Until is_airlock_api 0.5.0 gives Decided its wire form, no post is
    // read as naming teams-reply, so it follows and answers nothing.
    drawsFrom: (_) => null,
    render: (_) => const RenderRefused('no Teams rendering yet'),
    source: _source,
    dryRun: dryRun,
    log: stdout.writeln,
  );
  stdout.writeln(
    'teams-reply: following $read as $_source'
    '${dryRun ? ', dry run' : ''}',
  );
  // However the follow ends, the service restarts it: a restart reads the
  // record from the start and answers only what is still unanswered.
  try {
    await reply.run();
    stderr.writeln('teams-reply: the record stopped the follow');
  } on Exception catch (e) {
    stderr.writeln('teams-reply: the follow failed: $e');
  }
  exit(75);
}
