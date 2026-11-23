/// One reply as the Teams requests that post it, for the loop to send:
///
///     teams-message --reply-endpoint '{"origin":"https://smba.trafficmanager.net",
///                     "pathPrefix":"/amer/v3/conversations/<id>/"}' \
///         --sign-in cam-teams \
///         [--turn 3] [--context-tokens 152000] [--context-window 200000]
///
/// reads the reply's text, UTF-8, on stdin, and prints the requests as one
/// JSON array of is_effects' encodeProposedRequest, in posting order, on
/// stdout.
/// The reply endpoint is is_effects' AddressPrefix as the logbook recorded
/// it for the conversation, passed as it is; nothing here works it out
/// again or reaches the network. The footer says the turn and how full the
/// model's context is, each when given.
///
/// Exit: 0 printed, at least one request; 64 usage; 65 the text on stdin was
/// not usable. On a nonzero exit nothing is printed on stdout.
library;

import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';
import 'package:is_teams_module/is_teams_module.dart';

const usage =
    'usage: teams-message --reply-endpoint JSON --sign-in NAME '
    '[--turn N] [--context-tokens N] [--context-window N] < text';

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
    '--turn',
    '--context-tokens',
    '--context-window',
  };
  for (var i = 0; i < args.length; i += 2) {
    // wire-ok: command-line flags, read once here.
    if (!known.contains(args[i]) || i + 1 >= args.length) {
      err.writeln('teams-message: unknown or valueless ${args[i]}\n$usage');
      return 64;
    }
    if (options.containsKey(args[i])) {
      err.writeln('teams-message: ${args[i]} given twice\n$usage');
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
    err.writeln('teams-message: --reply-endpoint: ${e.message}\n$usage');
    return 64;
  }
  final signIn = SignIn.parse(options['--sign-in'] ?? '');
  if (signIn == null) {
    err.writeln('teams-message: --sign-in is needed and must parse\n$usage');
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
    err.writeln('teams-message: a count is not a whole number\n$usage');
    return 64;
  }

  final String text;
  try {
    text = await input.transform(const Utf8Decoder()).join();
  } on FormatException {
    err.writeln('teams-message: stdin is not UTF-8');
    return 65;
  }
  if (text.trim().isEmpty) {
    err.writeln('teams-message: nothing to say on stdin');
    return 65;
  }

  final requests = teamsMessageRequests(
    text: text,
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
