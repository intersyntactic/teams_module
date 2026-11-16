import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

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
  RecordAnswer answer = const Recorded('ee');
  Exception? tipFails;

  final log = <String>[];

  TeamsReply reply({
    bool dryRun = false,
    Rendering Function(List<FollowedEntry>)? render,
  }) => TeamsReply(
    follow: (kinds) async* {
      expect(kinds, ['decided']);
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
    drawsFrom: (d) {
      final post = jsonDecode(utf8.decode(d.body)) as Map<String, Object?>;
      return post['renderer'] == 'teams-reply'
          ? (post['entries']! as List).cast<String>()
          : null;
    },
    render:
        render ??
        (es) => RenderedBody(es.map((e) => utf8.decode(e.body)).join('|')),
    source: 'f00d',
    dryRun: dryRun,
    log: log.add,
  );
}

FollowedEntry _decided(
  String hash, {
  String renderer = 'teams-reply',
  List<String> entries = const ['t1'],
}) => _entry(
  hash,
  'decided',
  jsonEncode({'renderer': renderer, 'entries': entries}),
);

void main() {
  final turn = GotEntry(_entry('t1', 'turn', 'hello'));

  test(
    'renders a post naming it, following its Decided, with the source',
    () async {
      final r = _Record(decided: [_decided('d1')], entries: {'t1': turn});
      await r.reply().run();
      expect(r.written, hasLength(1));
      final w = r.written.single;
      expect(w.kind, 'rendered');
      expect(w.follows, 'd1');
      expect(w.body, {'decided': 'd1', 'body': 'hello', 'source': 'f00d'});
      expect(r.log.last, 'teams-reply: caught up at d1');
    },
  );

  test('draws from the entries in the order the post names them', () async {
    final r = _Record(
      decided: [
        _decided('d1', entries: ['t2', 't1']),
      ],
      entries: {'t1': turn, 't2': GotEntry(_entry('t2', 'turn', 'there'))},
    );
    await r.reply().run();
    expect(r.written.single.body['body'], 'there|hello');
  });

  test('leaves a post naming another renderer alone', () async {
    final r = _Record(
      decided: [_decided('d1', renderer: 'slack-reply')],
      entries: {'t1': turn},
    );
    await r.reply().run();
    expect(r.written, isEmpty);
  });

  test('leaves an answered post alone: its chain has moved past it', () async {
    final r = _Record(
      decided: [_decided('d1')],
      entries: {'t1': turn},
      tips: {'d1': 'r1'},
    );
    await r.reply().run();
    expect(r.written, isEmpty);
  });

  test(
    'records a refusal for an entry never recorded, or unreadable',
    () async {
      final r = _Record(
        decided: [
          _decided('d1', entries: ['t1', 'gone']),
          _decided('d2', entries: ['bad']),
        ],
        entries: {'t1': turn, 'bad': const GotUnreadable('corrupt')},
      );
      await r.reply().run();
      expect(r.written.map((w) => w.body['refused']), [
        'entry gone was never recorded',
        'entry bad is corrupt',
      ]);
      expect(r.written.every((w) => !w.body.containsKey('body')), isTrue);
    },
  );

  test("records the renderer's own refusal", () async {
    final r = _Record(decided: [_decided('d1')], entries: {'t1': turn});
    await r.reply(render: (_) => const RenderRefused('no text')).run();
    expect(r.written.single.body, {
      'decided': 'd1',
      'refused': 'no text',
      'source': 'f00d',
    });
  });

  test('a dry run renders and logs, and writes nothing', () async {
    final r = _Record(decided: [_decided('d1')], entries: {'t1': turn});
    await r.reply(dryRun: true).run();
    expect(r.written, isEmpty);
    expect(r.log, contains('teams-reply: would render d1 as a body of 5 B'));
  });

  test(
    'a tip refusal is "already answered"; any other is logged as one',
    () async {
      final r = _Record(decided: [_decided('d1')], entries: {'t1': turn})
        ..answer = const RecordRefused('not-tip r9');
      await r.reply().run();
      expect(r.log, contains('teams-reply: d1 already answered'));

      final s = _Record(decided: [_decided('d1')], entries: {'t1': turn})
        ..answer = const RecordRefused('kind rendered for user 990');
      await s.reply().run();
      expect(
        s.log,
        contains(
          'teams-reply: refused rendering d1: kind rendered for user 990',
        ),
      );
    },
  );

  test('a read that fails leaves the post unanswered, never refused', () async {
    final r = _Record(decided: [_decided('d1')], entries: {'t1': turn})
      ..tipFails = const SocketException('gone');
    await r.reply().run();
    expect(r.written, isEmpty);
    expect(r.log.first, startsWith('teams-reply: left d1 unanswered'));
  });
}
