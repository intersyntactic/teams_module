/// The relay's way to the record: the journal writer's Unix socket.
///
/// An arrival goes straight to the record (Nick, 15 Nov 17:04): nothing is
/// decided about it, so nothing stands between the relay and the writer.
/// The writer knows the relay by the user at the other end of its socket,
/// and its sender table says that user may send `arrived`.
///
/// The wire is `is_journal` 0.5.0's service: one connection per entry, the
/// request `<kind>\n<follows>\n<body>` with the write side then closed, and
/// one line back, `ok <entry hash>`, `refused <why>` or `failed <why>`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What the writer said became of one arrival.
sealed class RecordAnswer {
  const RecordAnswer();

  /// The writer's answer [line], read strictly: anything but one of its
  /// three answers is [RecordUnanswered], so Teams is sent a 5xx and tries
  /// again. Sending it again can at worst record an arrival twice, which
  /// whatever reads the record dedupes; reading an answer it can't read as
  /// recorded could lose one.
  static RecordAnswer read(String line) => switch (line.split(' ')) {
    ['ok', final hash] when _hex.hasMatch(hash) => Recorded(hash),
    ['refused', final why, ...final rest] => RecordRefused(
      [why, ...rest].join(' '),
    ),
    ['failed', final why, ...final rest] => RecordFailed(
      [why, ...rest].join(' '),
    ),
    _ => RecordUnanswered('not an answer the writer gives: $line'),
  };

  static final _hex = RegExp(r'^[0-9a-f]+$');
}

/// Recorded: Teams may be told it arrived.
final class Recorded extends RecordAnswer {
  const Recorded(this.entry);

  /// The entry's hash, in hex.
  final String entry;
}

/// Refused before anything was added: Teams is sent a 5xx and sends it
/// again. A refusal of the kind itself means the sender table doesn't let
/// the relay's user send `arrived`, which no retry will fix: the log says
/// so.
final class RecordRefused extends RecordAnswer {
  const RecordRefused(this.why);
  final String why;
}

/// The add failed partway, and the entry may be in anyway (the writer reads
/// its chains back rather than guess). Sending it again could record it
/// twice, so Teams is told it arrived, and the failure is logged for a
/// person to look at.
final class RecordFailed extends RecordAnswer {
  const RecordFailed(this.why);
  final String why;
}

/// No answer that could be read: the socket unreachable, closed before
/// answering, silent past the deadline, or an answer the writer doesn't
/// give. Teams is sent a 5xx and sends it again.
final class RecordUnanswered extends RecordAnswer {
  const RecordUnanswered(this.why);
  final String why;
}

/// Records [bytes] from [source] at the writer's [socketPath], as an
/// `arrived` entry that starts its own chain. The entry holds
/// `{"at", "source", "bytes"}`, the bytes base64 and exactly as they came,
/// the form the airlock gave arrivals, so reading one back doesn't change.
/// Teams gives up on a request after 15 seconds, so [timeout] stays inside
/// that.
Future<RecordAnswer> recordArrival(
  String socketPath, {
  required String source,
  required Uint8List bytes,
  DateTime? at,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final entry = utf8.encode(
    jsonEncode({
      'at': (at ?? DateTime.now().toUtc()).toIso8601String(),
      'source': source,
      'bytes': base64Encode(bytes),
    }),
  );
  Socket? socket;
  try {
    return await () async {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      socket!
        ..add(utf8.encode('arrived\n-\n'))
        ..add(entry);
      // The writer reads the request to its end: closing the write side is
      // what tells it the request is whole.
      await socket!.close();
      final answer = (await utf8.decoder.bind(socket!).join()).trim();
      return answer.isEmpty
          ? const RecordUnanswered('closed before answering')
          : RecordAnswer.read(answer);
    }().timeout(timeout);
  } on TimeoutException {
    return RecordUnanswered('no answer within ${timeout.inSeconds}s');
  } on SocketException catch (e) {
    return RecordUnanswered('socket: ${e.message}');
  } finally {
    socket?.destroy();
  }
}
