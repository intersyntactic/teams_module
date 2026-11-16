/// The follower's way to the record: the journal writer's Unix socket.
///
/// The wire is `is_journal` 0.5.0's service: one connection per entry, the
/// request `<kind>\n<follows>\n<body>` with the write side then closed, and
/// one line back, `ok <entry hash>`, `refused <why>` or `failed <why>`. The
/// writer knows the follower by the user at the other end of its socket, and
/// its sender table says which kinds that user may send.
///
/// The Teams relay has its own copy of this wire (teams_module's
/// `recordEvent`), so the follower carries none of the relay's code. Both go
/// when the journal ships one client for its writer.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What the writer said became of one entry.
sealed class RecordAnswer {
  const RecordAnswer();

  /// The writer's answer [line], read strictly: anything but one of its
  /// three answers is [RecordUnanswered].
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

/// Recorded as [entry].
final class Recorded extends RecordAnswer {
  const Recorded(this.entry);

  /// The entry's hash, in hex.
  final String entry;
}

/// Refused before anything was added: `not-tip <hash>` when the entry it
/// follows has been followed already, or the sender table's refusal.
final class RecordRefused extends RecordAnswer {
  const RecordRefused(this.why);
  final String why;
}

/// The add failed partway, and the entry may be in anyway: the writer reads
/// its chains back rather than guess.
final class RecordFailed extends RecordAnswer {
  const RecordFailed(this.why);
  final String why;
}

/// No answer that could be read: the socket unreachable, closed before
/// answering, silent past the deadline, or an answer the writer doesn't
/// give.
final class RecordUnanswered extends RecordAnswer {
  const RecordUnanswered(this.why);
  final String why;
}

/// Records [body] as an entry of [kind] at the writer's [socketPath],
/// following [follows], or starting a chain of its own when null.
Future<RecordAnswer> writeEntry(
  String socketPath, {
  required String kind,
  String? follows,
  required List<int> body,
  Duration timeout = const Duration(seconds: 10),
}) async {
  Socket? socket;
  try {
    return await () async {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      socket!
        ..add(utf8.encode('$kind\n${follows ?? '-'}\n'))
        ..add(body);
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
