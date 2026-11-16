import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

void main() {
  group('an answer', () {
    test('ok and a hash in hex is recorded', () {
      final a = RecordAnswer.read('ok 0a1b2c');
      expect((a as Recorded).entry, '0a1b2c');
    });

    test('refused, with why', () {
      final a = RecordAnswer.read('refused kind arrived for user 501');
      expect((a as RecordRefused).why, 'kind arrived for user 501');
    });

    test('failed, with why: the entry may be in', () {
      final a = RecordAnswer.read('failed No space left on device');
      expect((a as RecordFailed).why, 'No space left on device');
    });

    test('anything else is unanswered, never recorded', () {
      for (final line in [
        '',
        'ok',
        'ok XYZ',
        'ok 0a 1b',
        'OK 0a',
        'refused',
        'failed',
        '{"id":"0a"}',
      ]) {
        expect(RecordAnswer.read(line), isA<RecordUnanswered>(), reason: line);
      }
    });
  });

  group('recording an event', () {
    late Directory dir;
    late String path;
    ServerSocket? server;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('record');
      path = '${dir.path}/j.sock';
    });

    tearDown(() async {
      await server?.close();
      server = null;
      dir.deleteSync(recursive: true);
    });

    /// A writer that reads each request to its end, as the real one does,
    /// hands it to [sent], and answers [reply], or nothing when null.
    Future<void> writer(
      FutureOr<String?> Function(Uint8List request) reply, {
      void Function(Uint8List request)? sent,
    }) async {
      server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      server!.listen((socket) async {
        final request = BytesBuilder();
        await for (final chunk in socket) {
          request.add(chunk);
        }
        final bytes = request.takeBytes();
        sent?.call(bytes);
        final r = await reply(bytes);
        if (r != null) socket.add(utf8.encode('$r\n'));
        await socket.close();
      });
    }

    test('sends an arrived entry starting its own chain: at, source, and '
        'the bytes exactly, in base64', () async {
      Uint8List? request;
      await writer((_) => 'ok ab', sent: (r) => request = r);
      final bytes = Uint8List.fromList(utf8.encode('{  "text" :"x"}é'));
      final a = await recordEvent(
        path,
        source: 'teams',
        bytes: bytes,
        at: DateTime.utc(2026, 11, 15, 6),
      );
      expect((a as Recorded).entry, 'ab');
      final text = utf8.decode(request!);
      expect(text, startsWith('arrived\n-\n'));
      final entry = jsonDecode(
        text.substring('arrived\n-\n'.length),
      ) as Map<String, Object?>;
      expect(entry.keys, ['at', 'source', 'bytes']);
      expect(entry['at'], '2026-11-15T06:00:00.000Z');
      expect(entry['source'], 'teams');
      expect(base64Decode(entry['bytes']! as String), bytes);
    });

    test('reads the answer it gets back', () async {
      await writer((_) => 'failed disk full');
      final a = await recordEvent(path, source: 'teams', bytes: Uint8List(1));
      expect((a as RecordFailed).why, 'disk full');
    });

    test('is unanswered when nothing listens', () async {
      final a = await recordEvent(path, source: 'teams', bytes: Uint8List(1));
      expect(a, isA<RecordUnanswered>());
    });

    test('is unanswered when the writer closes without answering', () async {
      await writer((_) => null);
      final a = await recordEvent(path, source: 'teams', bytes: Uint8List(1));
      expect((a as RecordUnanswered).why, 'closed before answering');
    });

    test('is unanswered when no answer comes in time', () async {
      await writer((_) => Completer<String?>().future);
      final a = await recordEvent(
        path,
        source: 'teams',
        bytes: Uint8List(1),
        timeout: const Duration(milliseconds: 200),
      );
      expect(a, isA<RecordUnanswered>());
    });
  });
}
