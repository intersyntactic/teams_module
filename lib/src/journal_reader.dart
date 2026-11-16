/// A reader of the record: the journal's read socket, which can only read.
///
/// The wire is `is_journal`'s reader protocol. A reader sends one line and
/// reads the answer:
///
/// - `follow <kinds> <after>`: every entry of those kinds after `<after>`
///   (`-` for the start), then each new one as it is added. Each comes as
///   `entry <hash> <kind> <follows> <length>`, a newline, and exactly
///   `<length>` bytes; between the backlog and the first new entry comes
///   `caught-up <head>`.
/// - `tip <entry>`: answered `tip <hash>`, the tip of that entry's chain.
/// - `get <entry>` (is_journal 0.6.0): the entry's frame with a sixth word,
///   the 96-byte journal entry in hex, then its bytes; or `none <hash>`
///   (never recorded), `unreadable <hash> missing|corrupt`, `failed <why>`
///   or `refused not-a-request`.
///
/// The bytes are the whole request as recorded, `<kind>\n<follows>\n`
/// included. A frame carrying the journal entry is checked against it: the
/// entry hashes to the frame's hash, and its bytes 64–95 are the sha256 of
/// the bytes. `follow` frames carry no entry yet, so what they hand on is
/// the socket's word.
///
/// A stand-in until is_journal_reader (journal-0f) ships one client for
/// this protocol; delete it then.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_content_id/is_content_id.dart' show sha256;

/// What a follow hands on: an entry, or the moment the backlog ended.
sealed class Followed {
  const Followed();
}

/// One recorded entry: its [hash], its [kind], the entry it [follows] (null
/// when it starts a chain), and its [recorded] bytes, the header included.
/// [checked] says they were checked against the journal's entry.
final class FollowedEntry extends Followed {
  const FollowedEntry(
    this.hash,
    this.kind,
    this.follows,
    this.recorded, {
    this.checked = false,
  });

  final String hash;
  final String kind;
  final String? follows;
  final Uint8List recorded;
  final bool checked;

  /// The bytes after the `<kind>\n<follows>\n` header; all of them for an
  /// entry recorded without one (kind `-`).
  Uint8List get body {
    if (kind == '-') return recorded;
    final first = recorded.indexOf(10);
    final second = first < 0 ? -1 : recorded.indexOf(10, first + 1);
    return second < 0
        ? Uint8List(0)
        : Uint8List.sublistView(recorded, second + 1);
  }
}

/// The backlog has been read: everything after this was added while
/// following. [head] is the journal's last entry of any kind when the
/// backlog ended, or null for an empty journal.
final class CaughtUp extends Followed {
  const CaughtUp(this.head);

  final String? head;
}

/// What `get` found.
sealed class Got {
  const Got();
}

/// The entry, as a follow would have handed it on.
final class GotEntry extends Got {
  const GotEntry(this.entry);

  final FollowedEntry entry;
}

/// No entry by that hash was ever recorded.
final class GotNone extends Got {
  const GotNone();
}

/// The entry was recorded, but its bytes are [why]: `missing` or `corrupt`.
final class GotUnreadable extends Got {
  const GotUnreadable(this.why);

  final String why;
}

/// The reader broke the protocol, or the socket did: nothing it says past
/// this point is trusted.
final class JournalReadException implements Exception {
  const JournalReadException(this.message);

  final String message;

  @override
  String toString() => 'JournalReadException: $message';
}

/// The read socket at [socketPath].
final class JournalReader {
  const JournalReader(this.socketPath);

  final String socketPath;

  /// Every entry of [kinds] after [after] (null for the start), then a
  /// [CaughtUp], then each new one, for as long as the stream is listened
  /// to. Cancelling the subscription closes the socket.
  Stream<Followed> follow(Iterable<String> kinds, {String? after}) async* {
    final socket = await _connect();
    try {
      socket.add(utf8.encode('follow ${kinds.join(',')} ${after ?? '-'}\n'));
      await socket.flush();
      final frames = _Frames(socket);
      while (true) {
        final line = await frames.line();
        if (line == null) return;
        switch (line.split(' ')) {
          case ['caught-up', final head]:
            yield CaughtUp(head == '-' ? null : head);
          case ['entry', ...]:
            yield await _entry(line, frames);
          default:
            throw JournalReadException('not a follow frame: $line');
        }
      }
    } finally {
      socket.destroy();
    }
  }

  /// The tip of [entry]'s chain: [entry] itself until something follows it.
  Future<String> tip(String entry) async {
    final socket = await _connect();
    try {
      socket.add(utf8.encode('tip $entry\n'));
      await socket.flush();
      final line = await _Frames(socket).line();
      return switch (line?.split(' ')) {
        ['tip', final hash] => hash,
        _ => throw JournalReadException('not a tip answer: $line'),
      };
    } finally {
      socket.destroy();
    }
  }

  /// The entry named [entry].
  Future<Got> get(String entry) async {
    final socket = await _connect();
    try {
      socket.add(utf8.encode('get $entry\n'));
      await socket.flush();
      final frames = _Frames(socket);
      final line = await frames.line();
      return switch (line?.split(' ')) {
        ['none', _] => const GotNone(),
        ['unreadable', _, final why] => GotUnreadable(why),
        ['entry', _, _, _, _, _] => switch (await _entry(line!, frames)) {
          final e when e.hash != entry => throw JournalReadException(
            'asked for $entry, got ${e.hash}',
          ),
          final e => GotEntry(e),
        },
        _ => throw JournalReadException('not a checked get answer: $line'),
      };
    } finally {
      socket.destroy();
    }
  }

  Future<Socket> _connect() => Socket.connect(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  );

  static Future<FollowedEntry> _entry(String line, _Frames frames) async {
    final parts = line.split(' ');
    final length = parts.length == 5 || parts.length == 6
        ? int.tryParse(parts[4])
        : null;
    if (length == null || length < 0) {
      throw JournalReadException('not an entry frame: $line');
    }
    final [_, hash, kind, follows, _, ...rest] = parts;
    final recorded = await frames.bytes(length);
    if (recorded == null) {
      throw JournalReadException('closed inside entry $hash');
    }
    if (rest case [final entryHex]) _check(hash, entryHex, recorded);
    return FollowedEntry(
      hash,
      kind,
      follows == '-' ? null : follows,
      recorded,
      checked: rest.isNotEmpty,
    );
  }

  /// Throws unless the 96-byte journal entry [entryHex] hashes to [hash]
  /// and names [recorded] (its bytes 64–95 are their sha256).
  static void _check(String hash, String entryHex, Uint8List recorded) {
    final entry = _unhex(entryHex);
    if (entry == null || entry.length != 96) {
      throw JournalReadException('entry $hash: not a 96-byte entry');
    }
    if (_hex(sha256(entry)) != hash) {
      throw JournalReadException('entry $hash: the entry hashes elsewhere');
    }
    if (_hex(Uint8List.sublistView(entry, 64, 96)) != _hex(sha256(recorded))) {
      throw JournalReadException('entry $hash: the bytes are not its object');
    }
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List? _unhex(String s) {
    if (s.length.isOdd || !RegExp(r'^[0-9a-f]*$').hasMatch(s)) return null;
    return Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);
  }
}

/// The socket's bytes, read as lines and as runs of exact length.
final class _Frames {
  _Frames(Stream<List<int>> source) : _source = StreamIterator(source);

  final StreamIterator<List<int>> _source;
  final _buffer = BytesBuilder(copy: false);
  var _held = Uint8List(0);

  /// The next line, without its newline, or null at the end. Lines are
  /// ASCII on this wire; a line too long to be a frame is a broken reader.
  Future<String?> line() async {
    while (true) {
      final at = _held.indexOf(10);
      if (at >= 0) {
        final line = ascii.decode(Uint8List.sublistView(_held, 0, at));
        _held = Uint8List.sublistView(_held, at + 1);
        return line;
      }
      if (_held.length > 1024) {
        throw const JournalReadException('a frame line past 1024 bytes');
      }
      if (!await _more()) {
        if (_held.isEmpty) return null;
        throw const JournalReadException('closed inside a frame line');
      }
    }
  }

  /// Exactly [length] bytes, or null if the socket closes first.
  Future<Uint8List?> bytes(int length) async {
    while (_held.length < length) {
      if (!await _more()) return null;
    }
    final out = Uint8List.fromList(Uint8List.sublistView(_held, 0, length));
    _held = Uint8List.sublistView(_held, length);
    return out;
  }

  Future<bool> _more() async {
    if (!await _source.moveNext()) return false;
    _buffer
      ..add(_held)
      ..add(_source.current);
    _held = _buffer.takeBytes();
    return true;
  }
}
