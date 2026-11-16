import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:render_runner/render_runner.dart';
import 'package:test/test.dart';

/// An entry hash made of [c], so a test names entries by one character.
String _h(String c) => c * 64;

final _own = RendererId.parse(_h('f'))!;

FollowedEntry _entry(
  String hash,
  String kind,
  String body, {
  String? follows,
}) => FollowedEntry(
  hash,
  kind,
  follows,
  Uint8List.fromList(utf8.encode('$kind\n${follows ?? '-'}\n$body')),
);

/// A `post-decided` entry as the airlock writes it (airlock_api PR 11's
/// `DecidedPost.toJson`), written out by hand so the test holds the wire.
FollowedEntry _decided(
  String hash, {
  String? renderer,
  bool allow = true,
  List<String>? entries,
}) => _entry(
  hash,
  'post-decided',
  jsonEncode({
    'journeyPath': _h('9'),
    'place': null,
    'post': {
      'origin': 'https://smba.trafficmanager.net',
      'method': 'post',
      'path': '',
      'signIn': null,
      'headers': <String, String>{},
      'renderer': 'teams-reply',
      'entries': entries ?? [_h('1')],
    },
    'renderer': {'id': renderer ?? _own.hex, 'executable': _h('e')},
    'decision': allow
        ? {'allow': true, 'by': 'rules'}
        : {'allow': false, 'why': 'not granted', 'by': 'rules'},
  }),
);

/// A record held in memory: [decided] to follow, [entries] to get, the tip
/// of each chain, and what was written.
final class _Record {
  _Record({
    this.decided = const [],
    this.entries = const {},
    Map<String, String>? tips,
  }) : tips = tips ?? {};

  final List<FollowedEntry> decided;
  final Map<String, Got> entries;
  final Map<String, String> tips;
  final written =
      <({String kind, String follows, Map<String, Object?> body})>[];
  RecordAnswer answer = Recorded(_h('a'));
  Exception? tipFails;

  final log = <String>[];

  RenderRunner runner({
    bool dryRun = false,
    Outcome<String> Function(List<FollowedEntry>)? render,
  }) => RenderRunner(
    name: 'teams-reply',
    renderer: _own,
    follow: (kinds) async* {
      expect(kinds, ['post-decided']);
      yield* Stream.fromIterable(decided);
      yield CaughtUp(decided.isEmpty ? null : decided.last.hash);
    },
    tip: (e) async {
      if (tipFails case final f?) throw f;
      return tips[e] ?? e;
    },
    get: (e) async => entries[e] ?? const GotNone(),
    write: (kind, follows, body) async {
      written.add((
        kind: kind,
        follows: follows,
        body: jsonDecode(utf8.decode(body)) as Map<String, Object?>,
      ));
      return answer;
    },
    render: render ?? (es) => Ran(es.map((e) => utf8.decode(e.body)).join('|')),
    dryRun: dryRun,
    log: log.add,
  );
}

void main() {
  final d1 = _h('d');
  final turn = GotEntry(_entry(_h('1'), 'turn', 'hello'));

  test('renders an allowed post naming its renderer, following it, as '
      'Rendered reads it back', () async {
    final r = _Record(decided: [_decided(d1)], entries: {_h('1'): turn});
    await r.runner().run();
    final w = r.written.single;
    expect(w.kind, 'rendered');
    expect(w.follows, d1);
    expect(w.body, {
      'decided': d1,
      'renderer': _own.hex,
      'body': {'kind': 'ran', 'output': 'hello'},
    });
    final back = Rendered.fromJson(w.body);
    expect(back.renderer, _own);
    expect((back.body as Ran<String>).output, 'hello');
    expect(r.log.last, 'teams-reply: caught up at $d1');
  });

  test('draws from the entries in the order the post names them', () async {
    final r = _Record(
      decided: [
        _decided(d1, entries: [_h('2'), _h('1')]),
      ],
      entries: {
        _h('1'): turn,
        _h('2'): GotEntry(_entry(_h('2'), 'turn', 'there')),
      },
    );
    await r.runner().run();
    expect((r.written.single.body['body']! as Map)['output'], 'there|hello');
  });

  test('leaves a post naming another renderer alone', () async {
    final r = _Record(
      decided: [_decided(d1, renderer: _h('0'))],
      entries: {_h('1'): turn},
    );
    await r.runner().run();
    expect(r.written, isEmpty);
  });

  test('leaves a denied post alone: the airlock closes it', () async {
    final r = _Record(
      decided: [_decided(d1, allow: false)],
      entries: {_h('1'): turn},
    );
    await r.runner().run();
    expect(r.written, isEmpty);
  });

  test('skips, and logs, an entry that is not a post', () async {
    final r = _Record(decided: [_entry(d1, 'post-decided', '{"x":1}')]);
    await r.runner().run();
    expect(r.written, isEmpty);
    expect(r.log.first, startsWith('teams-reply: skipped $d1: '));
  });

  test('leaves an answered post alone: its chain has moved past it', () async {
    final r = _Record(
      decided: [_decided(d1)],
      entries: {_h('1'): turn},
      tips: {d1: _h('2')},
    );
    await r.runner().run();
    expect(r.written, isEmpty);
  });

  test(
    'records a refusal for an entry never recorded, or unreadable',
    () async {
      final r = _Record(
        decided: [
          _decided(d1, entries: [_h('1'), _h('3')]),
          _decided(_h('c'), entries: [_h('4')]),
        ],
        entries: {_h('1'): turn, _h('4'): const GotUnreadable('corrupt')},
      );
      await r.runner().run();
      expect(r.written.map((w) => w.body['body']), [
        {'kind': 'refused', 'why': 'entry ${_h('3')} was never recorded'},
        {'kind': 'refused', 'why': 'entry ${_h('4')} is corrupt'},
      ]);
    },
  );

  test("records the renderer's own refusal", () async {
    final r = _Record(decided: [_decided(d1)], entries: {_h('1'): turn});
    await r.runner(render: (_) => const Refused('no text')).run();
    expect(r.written.single.body['body'], {
      'kind': 'refused',
      'why': 'no text',
    });
  });

  test('a dry run renders and logs, and writes nothing', () async {
    final r = _Record(decided: [_decided(d1)], entries: {_h('1'): turn});
    await r.runner(dryRun: true).run();
    expect(r.written, isEmpty);
    expect(r.log, contains('teams-reply: would render $d1 as a body of 5 B'));
  });

  test(
    'a tip refusal is "already answered"; any other is logged as one',
    () async {
      final r = _Record(decided: [_decided(d1)], entries: {_h('1'): turn})
        ..answer = RecordRefused('not-tip ${_h('9')}');
      await r.runner().run();
      expect(r.log, contains('teams-reply: $d1 already answered'));

      final s = _Record(decided: [_decided(d1)], entries: {_h('1'): turn})
        ..answer = const RecordRefused('kind rendered for user 990');
      await s.runner().run();
      expect(
        s.log,
        contains(
          'teams-reply: refused rendering $d1: kind rendered for user 990',
        ),
      );
    },
  );

  test('a read that fails leaves the post unanswered, never refused', () async {
    final r = _Record(decided: [_decided(d1)], entries: {_h('1'): turn})
      ..tipFails = const SocketException('gone');
    await r.runner().run();
    expect(r.written, isEmpty);
    expect(r.log.first, startsWith('teams-reply: left $d1 unanswered'));
  });

  test('a build that names no renderer has none', () {
    expect(compiledRenderer(), isNull);
  });
}
