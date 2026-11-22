/// The relay's way to the logbook: the logbook writer's Unix socket.
///
/// An event goes straight to the logbook (Nick, 15 Nov 17:04): nothing is
/// decided about it, so nothing stands between the relay and the writer.
/// The writer knows the relay by the user at the other end of its socket,
/// and its sender table says that user may send `event` (Nick, 16 Nov: an
/// event, not an arrival). Entries written before that are `arrived`, and
/// keep it: whatever reads the logbook's events reads both kinds.
///
/// The wire is `is_logbook` 0.2.0's service: one connection per entry, the
/// request `<kind>\n<previous>\n<body>` with the write side then closed, and
/// one line back, `ok <entry id>`, `refused <why>` or `failed <why>`. The id
/// is the hash of the whole request; each entry's own `at` keeps a resent
/// event from being refused as a duplicate.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What the writer said became of one event.
sealed class RecordAnswer {
  const RecordAnswer();

  /// The writer's answer [line], read strictly: anything but one of its
  /// three answers is [RecordUnanswered], so Teams is sent a 5xx and tries
  /// again. Sending it again can at worst record an event twice, which
  /// whatever reads the logbook dedupes; reading an answer it can't read as
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
/// the relay's user send `event`, which no retry will fix: the log says
/// so.
final class RecordRefused extends RecordAnswer {
  const RecordRefused(this.why);
  final String why;
}

/// The add failed partway, and the entry may be in anyway (the writer reads
/// its chains back rather than guess). Only `ok` gets Teams a 200 (Nick,
/// 16 Nov), so Teams is sent a 5xx and sends it again. That may record the
/// event twice, which costs nothing: whatever reads the logbook takes one
/// per key. Not sending it again could lose it.
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
/// `event` entry that starts its own chain. The entry holds
/// `{"at", "source", "bytes"}`, the bytes base64 and exactly as they came,
/// the form the logbook's first entries took, so reading one back doesn't
/// change. Teams gives up on a request after 15 seconds, so [timeout] stays
/// inside that.
Future<RecordAnswer> recordEvent(
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
        ..add(utf8.encode('event\n-\n'))
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
