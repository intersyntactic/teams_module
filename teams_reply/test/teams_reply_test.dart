import 'dart:convert';
import 'dart:typed_data';

import 'package:teams_reply/teams_reply.dart';
import 'package:test/test.dart';

Entry _turn(Object? json) =>
    Entry('turn', Uint8List.fromList(utf8.encode(jsonEncode(json))));

/// A closing turn as agent-loop-b6 writes it (TurnEnvelope.encode); the
/// node's form is b6's best guess, not yet pinned.
Entry _reply(String text) => _turn({
  'node': {
    'shape': 'ReplyText',
    'by': 'agent:bea',
    'answers': 'a' * 64,
    'text': text,
  },
  'provenance': {'kind': 'own'},
});

String _why(Drawn d) => (d as Refusal).why;

void main() {
  test('draws a ReplyText turn as a Teams message activity', () {
    final drawn = teamsReply([_reply('Hi, Ada — done.')]);
    expect((drawn as Body).text, '{"type":"message","text":"Hi, Ada — done."}');
  });

  test('draws the same body from the same entry, every time', () {
    final entry = _reply('same');
    expect(
      (teamsReply([entry]) as Body).text,
      (teamsReply([entry]) as Body).text,
    );
  });

  test('carries the text exactly, whatever it holds', () {
    const text = '"quoted"\n<at>not a mention</at> \u0000 😀';
    final body = (teamsReply([_reply(text)]) as Body).text;
    expect(jsonDecode(body), {'type': 'message', 'text': text});
  });

  test('refuses anything but one turn', () {
    expect(_why(teamsReply([])), contains('not none'));
    expect(
      _why(teamsReply([_reply('a'), _reply('b')])),
      contains('not turn, turn'),
    );
    expect(
      _why(teamsReply([Entry('event', Uint8List(0))])),
      contains('not event'),
    );
  });

  test('refuses a turn it cannot read', () {
    expect(
      _why(
        teamsReply([
          Entry('turn', Uint8List.fromList([0xff])),
        ]),
      ),
      startsWith('the turn is not JSON'),
    );
    expect(
      _why(
        teamsReply([
          _turn({'provenance': <String, Object?>{}}),
        ]),
      ),
      'the turn holds no node',
    );
    expect(
      _why(
        teamsReply([
          _turn({
            'node': {'shape': 'ReplyText'},
          }),
        ]),
      ),
      'the ReplyText holds no text',
    );
    expect(
      _why(
        teamsReply([
          _turn({
            'node': {'shape': 'ReplyText', 'text': 7},
          }),
        ]),
      ),
      'the ReplyText holds no text',
    );
  });

  test('refuses a turn of another shape', () {
    expect(
      _why(
        teamsReply([
          _turn({
            'node': {'shape': 'UserSaid', 'text': 'x'},
          }),
        ]),
      ),
      'a UserSaid turn draws no Teams reply',
    );
  });
}
