import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:is_effects/is_effects.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import '../bin/teams_message.dart' as app;

const origin = 'https://smba.trafficmanager.net';
const prefix = '/amer/v3/conversations/a%3A1personal/';
const endpointArgs = [
  '--reply-endpoint',
  '{"origin":"$origin","pathPrefix":"$prefix"}',
  '--sign-in',
  'cam-teams',
];

/// The app run on [args] with [stdin]: its exit code, the requests it
/// printed (decoded), and what it said on stderr.
Future<(int, List<ProposedRequest>, String)> run(
  List<String> args, {
  Object stdin = 'hi',
}) async {
  final out = StringBuffer(), err = StringBuffer();
  final code = await app.run(
    args,
    input: Stream.value(
      stdin is String ? utf8.encode(stdin) : stdin as List<int>,
    ), // cast-ok: test input
    out: out,
    err: err,
  );
  final printed = '$out';
  return (
    code,
    printed.isEmpty
        ? <ProposedRequest>[]
        : [
            for (final r in jsonDecode(printed) as List)
              decodeProposedRequest(r),
          ], // cast-ok: our own output
    '$err',
  );
}

/// The card's TextBlock texts in [request]'s message, in order.
List<String> texts(ProposedRequest request) => [
  for (final block in JsonObject.decode(
    request.body!,
  ).objects('attachments').single.object('content').objects('body'))
    block.string('text'),
];

void main() {
  test('prints one request: a post to the recorded endpoint, as the sign-in, '
      'with the turn and context in the footer', () async {
    final (code, requests, _) = await run([
      ...endpointArgs,
      '--turn',
      '3',
      '--context-tokens',
      '152000',
      '--context-window',
      '200000',
    ], stdin: 'Hello **Nick**');
    expect(code, 0);
    final r = requests.single;
    expect(r.origin, Origin.parse(origin));
    expect(r.method, Method.post);
    expect(r.path.value, '${prefix}activities');
    expect(r.signIn, SignIn.parse('cam-teams'));
    expect(texts(r), ['Hello **Nick**', 'turn 3 · context 152k of 200k (76%)']);
  });

  test('no turn or context given: no footer', () async {
    final (_, requests, _) = await run(endpointArgs);
    expect(texts(requests.single), ['hi']);
  });

  test('a long reply is several messages, each within the cap, the footer '
      'only on the last', () async {
    final text = List.filled(4000, 'a line of the reply').join('\n');
    final (code, requests, _) = await run([
      ...endpointArgs,
      '--turn',
      '1',
    ], stdin: text);
    expect(code, 0);
    expect(requests.length, greaterThan(1));
    for (final r in requests) {
      expect(
        utf8.encode(r.body!).length,
        lessThanOrEqualTo(teamsMessageByteCap),
      );
      expect(r.path.value, '${prefix}activities');
    }
    expect(texts(requests.last).last, 'turn 1');
    for (final r in requests.take(requests.length - 1)) {
      expect(texts(r), hasLength(1));
    }
  });

  test('past the most messages, the reply stops there and says it was cut '
      'off', () async {
    final text = List.filled(40000, 'a line of a very long reply').join('\n');
    final (code, requests, _) = await run(endpointArgs, stdin: text);
    expect(code, 0);
    expect(requests, hasLength(teamsReplyMaxMessages));
    expect(texts(requests.last), contains('(reply cut off)'));
    expect(
      utf8.encode(requests.last.body!).length,
      lessThanOrEqualTo(teamsMessageByteCap),
    );
  });

  test('a bad call is exit 64 and prints nothing', () async {
    for (final args in [
      <String>[],
      [...endpointArgs, '--colour', 'red'],
      [...endpointArgs, '--turn'],
      [...endpointArgs, '--sign-in', 'twice'],
      ['--reply-endpoint', endpointArgs[1]],
      ['--sign-in', 'cam-teams'],
      ['--origin', origin, '--path-prefix', prefix, '--sign-in', 'x'],
      [
        '--reply-endpoint',
        '{"origin":"$origin","pathPrefix":"/no/slash"}',
        '--sign-in',
        'x',
      ],
      [
        '--reply-endpoint',
        '{"origin":"not a url","pathPrefix":"$prefix"}',
        '--sign-in',
        'x',
      ],
      ['--reply-endpoint', 'not json', '--sign-in', 'x'],
      [...endpointArgs, '--turn', 'three'],
    ]) {
      final (code, requests, err) = await run(args);
      expect(code, 64, reason: '$args');
      expect(requests, isEmpty, reason: '$args');
      expect(err, contains('usage'), reason: '$args');
    }
  });

  test('empty or non-UTF-8 stdin is exit 65 and prints nothing', () async {
    for (final stdin in <Object>[
      '',
      '  \n',
      [0xff, 0xfe],
    ]) {
      final (code, requests, _) = await run(endpointArgs, stdin: stdin);
      expect(code, 65, reason: '$stdin');
      expect(requests, isEmpty);
    }
  });
}
