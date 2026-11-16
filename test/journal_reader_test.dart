import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_content_id/is_content_id.dart' show sha256;
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// [recorded] as the journal keeps it: a 96-byte entry whose last 32 bytes
/// are the object's sha256, and the entry's own hash.
({String hash, String entryHex}) _entryOf(Uint8List recorded) {
  final entry = Uint8List(96)..setRange(64, 96, sha256(recorded));
  return (hash: _hex(sha256(entry)), entryHex: _hex(entry));
}

void main() {
  late Directory dir;
  late String path;
  ServerSocket? server;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('reader');
    path = '${dir.path}/r.sock';
  });

  tearDown(() async {
    await server?.close();
    server = null;
    dir.deleteSync(recursive: true);
  });

  /// A read socket that hands [sent] the request line and answers [reply],
  /// a byte at a time, so every frame arrives split.
  Future<void> reader(
    List<int> Function(String line) reply, {
    void Function(String line)? sent,
    bool close = true,
  }) async {
    server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    server!.listen((socket) async {
      // Listened to, never cancelled: cancelling would close the socket
      // before the answer is written.
      final heard = <int>[];
      final asked = Completer<String>();
      socket.listen((chunk) {
        heard.addAll(chunk);
        final end = heard.indexOf(10);
        if (end >= 0 && !asked.isCompleted) {
          asked.complete(utf8.decode(heard.sublist(0, end)));
        }
      });
      final line = await asked.future;
      sent?.call(line);
      for (final b in reply(line)) {
        socket.add([b]);
        await socket.flush();
      }
      if (close) await socket.close();
    });
  }

  final recorded = Uint8List.fromList(utf8.encode('decided\n-\n{"a":1}'));

  test('follow sends kinds and a start, and reads entries and caught-up '
      'split anywhere', () async {
    String? asked;
    await reader(
      (_) => [
        ...utf8.encode('entry aa decided - ${recorded.length}\n'),
        ...recorded,
        ...utf8.encode('caught-up aa\n'),
        ...utf8.encode('entry bb rendered aa 3\nxyz'),
      ],
      sent: (l) => asked = l,
    );
    final got = await JournalReader(path)
        .follow(['decided', 'rendered'])
        .toList();
    expect(asked, 'follow decided,rendered -');
    expect(got, hasLength(3));
    final first = got[0] as FollowedEntry;
    expect(first.hash, 'aa');
    expect(first.kind, 'decided');
    expect(first.follows, isNull);
    expect(first.recorded, recorded);
    expect(utf8.decode(first.body), '{"a":1}');
    expect(first.checked, isFalse);
    expect((got[1] as CaughtUp).head, 'aa');
    final third = got[2] as FollowedEntry;
    expect(third.follows, 'aa');
    expect(utf8.decode(third.recorded), 'xyz');
  });

  test('follow from an entry names it', () async {
    String? asked;
    await reader((_) => utf8.encode('caught-up -\n'), sent: (l) => asked = l);
    final got = await JournalReader(path).follow(['*'], after: 'cc').toList();
    expect(asked, 'follow * cc');
    expect((got.single as CaughtUp).head, isNull);
  });

  test(
    'follow throws on a frame it does not know, and on a short entry',
    () async {
      await reader((_) => utf8.encode('hello\n'));
      await expectLater(
        JournalReader(path).follow(['*']).toList(),
        throwsA(isA<JournalReadException>()),
      );
      await server!.close();
      await reader((_) => utf8.encode('entry aa k - 10\nabc'));
      await expectLater(
        JournalReader(path).follow(['*']).toList(),
        throwsA(isA<JournalReadException>()),
      );
    },
  );

  test('tip', () async {
    String? asked;
    await reader((_) => utf8.encode('tip bb\n'), sent: (l) => asked = l);
    expect(await JournalReader(path).tip('aa'), 'bb');
    expect(asked, 'tip aa');
  });

  group('get', () {
    test('an entry checked against the journal entry', () async {
      final e = _entryOf(recorded);
      await reader(
        (_) => [
          ...utf8.encode(
            'entry ${e.hash} decided - ${recorded.length} ${e.entryHex}\n',
          ),
          ...recorded,
        ],
      );
      final got = await JournalReader(path).get(e.hash) as GotEntry;
      expect(got.entry.checked, isTrue);
      expect(got.entry.recorded, recorded);
      expect(utf8.decode(got.entry.body), '{"a":1}');
    });

    test('refuses bytes that are not the entry\'s object', () async {
      final e = _entryOf(recorded);
      final other = utf8.encode('decided\n-\n{"a":2}');
      await reader(
        (_) => [
          ...utf8.encode(
            'entry ${e.hash} decided - ${other.length} ${e.entryHex}\n',
          ),
          ...other,
        ],
      );
      await expectLater(
        JournalReader(path).get(e.hash),
        throwsA(isA<JournalReadException>()),
      );
    });

    test('refuses an entry that hashes elsewhere', () async {
      final e = _entryOf(recorded);
      final wrong = 'f${e.hash.substring(1)}';
      await reader(
        (_) => [
          ...utf8.encode(
            'entry $wrong decided - ${recorded.length} ${e.entryHex}\n',
          ),
          ...recorded,
        ],
      );
      await expectLater(
        JournalReader(path).get(wrong),
        throwsA(isA<JournalReadException>()),
      );
    });

    test('refuses an answer with no journal entry to check against', () async {
      await reader(
        (_) => [
          ...utf8.encode('entry aa decided - ${recorded.length}\n'),
          ...recorded,
        ],
      );
      await expectLater(
        JournalReader(path).get('aa'),
        throwsA(isA<JournalReadException>()),
      );
    });

    test('none and unreadable', () async {
      await reader(
        (line) => utf8.encode(
          line == 'get aa' ? 'none aa\n' : 'unreadable bb corrupt\n',
        ),
      );
      expect(await JournalReader(path).get('aa'), isA<GotNone>());
      expect(
        (await JournalReader(path).get('bb') as GotUnreadable).why,
        'corrupt',
      );
    });
  });

  test('a body of an entry recorded without a header is all of it', () {
    final e = FollowedEntry('aa', '-', null, Uint8List.fromList([1, 2]));
    expect(e.body, [1, 2]);
  });
}
