import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

void main() {
  group('an answer', () {
    test('with only an id in hex is witnessed', () {
      final a = AirlockAnswer.read('{"id":"0a1b2c"}');
      expect((a as AirlockWitnessed).entry, '0a1b2c');
    });

    test('with an error and retry false is a record that failed partway', () {
      final a = AirlockAnswer.read('{"error":"object not kept","retry":false}');
      expect((a as AirlockRecordFailed).error, 'object not kept');
    });

    test('with only an error is not witnessed', () {
      final a = AirlockAnswer.read('{"error":"not a source"}');
      expect((a as AirlockNotWitnessed).error, 'not a source');
    });

    test('that is none of the three is not witnessed, never witnessed', () {
      for (final line in [
        'not json',
        '[]',
        '{}',
        '{"id":""}',
        '{"id":"XYZ"}',
        '{"id":"0a","error":"both"}',
        '{"id":"0a","extra":1}',
        '{"error":"x","retry":true}',
        '{"error":"x","retry":"false"}',
        '{"error":"x","retry":false,"extra":1}',
        '{"error":7}',
      ]) {
        expect(
          AirlockAnswer.read(line),
          isA<AirlockNotWitnessed>(),
          reason: line,
        );
      }
    });
  });

  group('witnessing through the airlock', () {
    late Directory dir;
    late String path;
    ServerSocket? server;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('airlock');
      path = '${dir.path}/a.sock';
    });

    tearDown(() async {
      await server?.close();
      server = null;
      dir.deleteSync(recursive: true);
    });

    /// An airlock that answers [reply] to whatever line it is sent, and
    /// hands that line to [sent].
    Future<void> airlock(
      FutureOr<String?> Function(String request) reply, {
      void Function(String request)? sent,
    }) async {
      server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      server!.listen((socket) async {
        await for (final line
            in utf8.decoder.bind(socket).transform(const LineSplitter())) {
          sent?.call(line);
          final r = await reply(line);
          if (r != null) socket.add(utf8.encode('$r\n'));
          await socket.close();
          break;
        }
      });
    }

    test(
      'sends one line: the source and the bytes exactly, in base64',
      () async {
        String? request;
        await airlock((_) => '{"id":"ab"}', sent: (r) => request = r);
        final bytes = Uint8List.fromList(utf8.encode('{  "text" :"x"}é'));
        final a = await witnessThroughAirlock(
          path,
          source: 'teams',
          bytes: bytes,
        );
        expect(a, isA<AirlockWitnessed>());
        final sent = jsonDecode(request!) as Map<String, Object?>;
        expect(sent.keys, ['source', 'bytes']);
        expect(sent['source'], 'teams');
        expect(base64Decode(sent['bytes']! as String), bytes);
      },
    );

    test('reads the answer it gets back', () async {
      await airlock((_) => '{"error":"partway","retry":false}');
      final a = await witnessThroughAirlock(
        path,
        source: 'teams',
        bytes: Uint8List(1),
      );
      expect((a as AirlockRecordFailed).error, 'partway');
    });

    test('is not witnessed when nothing listens', () async {
      final a = await witnessThroughAirlock(
        path,
        source: 'teams',
        bytes: Uint8List(1),
      );
      expect(a, isA<AirlockNotWitnessed>());
    });

    test(
      'is not witnessed when the airlock closes without answering',
      () async {
        await airlock((_) => null);
        final a = await witnessThroughAirlock(
          path,
          source: 'teams',
          bytes: Uint8List(1),
        );
        expect((a as AirlockNotWitnessed).error, 'closed before answering');
      },
    );

    test('is not witnessed when no answer comes in time', () async {
      await airlock((_) => Completer<String?>().future);
      final a = await witnessThroughAirlock(
        path,
        source: 'teams',
        bytes: Uint8List(1),
        timeout: const Duration(milliseconds: 200),
      );
      expect(a, isA<AirlockNotWitnessed>());
    });
  });
}
