/// The relay's way to the record: the airlock service's Unix socket.
///
/// The record has one writer, and only the airlock sends it `witnessed`
/// entries (RULINGS, enspyrco/intersyntactic PR 1138), so the relay keeps
/// no record of its own. It hands the airlock each accepted body, its bytes
/// exactly as Teams sent them and before anything has parsed them, and
/// answers Teams only once the airlock has said what became of them.
///
/// The wire is the airlock's (`bin/airlock_service.dart`, airlock b612846):
/// one connection per arrival, one JSON line each way.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checked_json/checked_json.dart';

/// What the airlock said became of one arrival.
sealed class AirlockAnswer {
  const AirlockAnswer();

  /// The airlock's answer [line], read strictly: anything that is not
  /// exactly one of the three answers is [AirlockNotWitnessed], so Teams
  /// is sent a 5xx and tries again. Sending it again can at worst record an
  /// arrival twice, which whatever reads the record already dedupes;
  /// treating an answer it can't read as witnessed could lose one.
  static AirlockAnswer read(String line) {
    final JsonObject answer;
    try {
      answer = JsonObject.decode(line);
    } on FormatException catch (e) {
      return AirlockNotWitnessed('answer is not a JSON object: ${e.message}');
    }
    final fields = answer.asUncheckedMap();
    return switch (fields) {
      {'id': final String id} when fields.length == 1 && _hex.hasMatch(id) =>
        AirlockWitnessed(id),
      {'error': final String error} when fields.length == 1 =>
        AirlockNotWitnessed(error),
      {'error': final String error, 'retry': false} when fields.length == 2 =>
        AirlockRecordFailed(error),
      _ => AirlockNotWitnessed('answer is none of the three: $line'),
    };
  }

  static final _hex = RegExp(r'^[0-9a-f]+$');
}

/// Witnessed: the writer answered `ok`. Teams may be told it arrived.
final class AirlockWitnessed extends AirlockAnswer {
  const AirlockWitnessed(this.entry);

  /// The record entry's hash, in hex.
  final String entry;
}

/// The record failed partway: the entry may already be in while its
/// object is not. Sending it again could record it twice, so Teams is told
/// it arrived, and the failure is logged for a person to look at.
final class AirlockRecordFailed extends AirlockAnswer {
  const AirlockRecordFailed(this.error);
  final String error;
}

/// Not witnessed: refused, unreachable, or an answer that couldn't be read.
/// Teams is sent a 5xx, so it sends the activity again.
final class AirlockNotWitnessed extends AirlockAnswer {
  const AirlockNotWitnessed(this.error);
  final String error;
}

/// Hands [bytes] from [source] to the airlock at [socketPath] and reads
/// its answer. A socket that can't be reached, a connection closed before
/// an answer, or no answer within [timeout] is [AirlockNotWitnessed]:
/// Teams gives up on a request after 15 seconds, so [timeout] stays inside
/// that.
Future<AirlockAnswer> witnessThroughAirlock(
  String socketPath, {
  required String source,
  required Uint8List bytes,
  Duration timeout = const Duration(seconds: 10),
}) async {
  Socket? socket;
  try {
    return await () async {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      socket!.add(
        utf8.encode(
          '${jsonEncode({'source': source, 'bytes': base64Encode(bytes)})}\n',
        ),
      );
      await socket!.flush();
      await for (final line
          in utf8.decoder.bind(socket!).transform(const LineSplitter())) {
        return AirlockAnswer.read(line);
      }
      return const AirlockNotWitnessed('closed before answering');
    }().timeout(timeout);
  } on TimeoutException {
    return AirlockNotWitnessed('no answer within ${timeout.inSeconds}s');
  } on SocketException catch (e) {
    return AirlockNotWitnessed('socket: ${e.message}');
  } finally {
    socket?.destroy();
  }
}
