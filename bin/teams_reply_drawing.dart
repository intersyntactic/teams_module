/// One reply drawn for Teams, its cards addressed and signed as the requests
/// that would post them, for the loop to propose to the airlock. It sends
/// and proposes nothing itself.
///
///     teams-reply-drawing \
///         --reply-endpoint '{"origin":"https://smba.trafficmanager.net",
///                     "pathPrefix":"/amer/v3/conversations/<id>/"}' \
///         --sign-in cam-teams --trajectory <64 hex> \
///         [--turn 3] [--context-tokens 152000] [--context-window 200000]
///
/// reads the reply's text, UTF-8, on stdin, and prints the requests as one
/// JSON array of is_effects' encodeProposedRequest, in posting order, on
/// stdout.
/// The reply endpoint is is_effects' AddressPrefix as the logbook recorded
/// it for the conversation, passed as it is; nothing here works it out
/// again or reaches the network. The footer says the turn and how full the
/// model's context is, each when given. The trajectory is the one the reply
/// is in, a TrajectoryId in hex: the reply's "Close trajectory" closes
/// that one, wherever and whenever it is pressed.
///
/// Exit: 0 printed, at least one request; 64 usage; 65 the text on stdin was
/// not usable. On a nonzero exit nothing is printed on stdout.
library;

import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;
import 'package:is_teams_module/is_teams_module.dart';

const usage =
    'usage: teams-reply-drawing --reply-endpoint JSON --sign-in NAME '
    '--trajectory HEX [--turn N] [--context-tokens N] [--context-window N] '
    '< text';

Future<void> main(List<String> args) async =>
    exit(await run(args, input: stdin, out: stdout, err: stderr));

/// The program, with its streams given, so a test can stand in for them.
Future<int> run(
  List<String> args, {
  required Stream<List<int>> input,
  required StringSink out,
  required StringSink err,
}) async {
  final options = <String, String>{};
  const known = {
    '--reply-endpoint',
    '--sign-in',
    '--trajectory',
    '--turn',
    '--context-tokens',
    '--context-window',
  };
  for (var i = 0; i < args.length; i += 2) {
    // wire-ok: command-line flags, read once here.
    if (!known.contains(args[i]) || i + 1 >= args.length) {
      err.writeln(
        'teams-reply-drawing: unknown or valueless ${args[i]}\n$usage',
      );
      return 64;
    }
    if (options.containsKey(args[i])) {
      err.writeln('teams-reply-drawing: ${args[i]} given twice\n$usage');
      return 64;
    }
    options[args[i]] = args[i + 1];
  }
  final AddressPrefix replyEndpoint;
  try {
    replyEndpoint = decodeAddressPrefix(
      jsonDecode(options['--reply-endpoint'] ?? ''),
      'reply endpoint',
    );
  } on FormatException catch (e) {
    err.writeln('teams-reply-drawing: --reply-endpoint: ${e.message}\n$usage');
    return 64;
  }
  final signIn = SignIn.parse(options['--sign-in'] ?? '');
  if (signIn == null) {
    err.writeln(
      'teams-reply-drawing: --sign-in is needed and must parse\n$usage',
    );
    return 64;
  }
  final trajectory = TrajectoryId.parse(options['--trajectory'] ?? '');
  if (trajectory == null) {
    err.writeln(
      'teams-reply-drawing: --trajectory is needed, a TrajectoryId in lower-case '
      'hex\n$usage',
    );
    return 64;
  }
  int? count(String flag) => switch (options[flag]) {
    null => null,
    final s => int.tryParse(s) ?? -1,
  };
  final turn = count('--turn');
  final contextTokens = count('--context-tokens');
  final contextWindow = count('--context-window');
  if ([turn, contextTokens, contextWindow].any((n) => n != null && n < 0)) {
    err.writeln('teams-reply-drawing: a count is not a whole number\n$usage');
    return 64;
  }

  final String text;
  try {
    text = await input.transform(const Utf8Decoder()).join();
  } on FormatException {
    err.writeln('teams-reply-drawing: stdin is not UTF-8');
    return 65;
  }
  if (text.trim().isEmpty) {
    err.writeln('teams-reply-drawing: nothing to say on stdin');
    return 65;
  }

  final requests = postTeamsReplyDrawing(
    text: text,
    trajectory: trajectory,
    replyEndpoint: replyEndpoint,
    signIn: signIn,
    footer: replyFooter(
      turn: turn,
      contextTokens: contextTokens,
      contextWindow: contextWindow,
    ),
  );
  out.write(jsonEncode([for (final r in requests) encodeProposedRequest(r)]));
  return 0;
}
