/// The HTTP front of the Teams module: the one endpoint Teams posts to.
///
/// It checks the token from the headers alone ([teamsToken]), so a sender
/// with no valid token is refused before its body is read. Then it reads
/// the body under a cap and a deadline, asks [teamsGateBody], responds at
/// once, and only then hands the [TeamsEvent] to [TeamsRelay.onEvent], so
/// nothing done with it can make Teams wait past its 15 seconds and send
/// again. It holds no Microsoft credential: the gate needs only the app id
/// and the public keys.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'record_event.dart';
import 'key_source.dart';
import 'teams_event.dart';
import 'teams_gate.dart';

final class TeamsRelay {
  TeamsRelay({
    required this.spec,
    required this.keys,
    this.onEvent = _logEvent,
    this.record,
    DateTime Function()? now,
    this.bodyTimeout = const Duration(seconds: 10),
    this.maxBodyBytes = 1024 * 1024,
    this.seenFor = const Duration(minutes: 10),
    this.seenMax = 5000,
    this.log = _stderr,
  }) : _now = now ?? DateTime.now;

  /// Where Teams posts: the Bot Framework's usual messaging path.
  static const path = '/api/messages';

  final TeamsSourceSpec spec;
  final BotFrameworkKeySource keys;

  /// What becomes of an event once Teams has its response. Defaults to a log
  /// line, so the relay runs end to end before a receiver is wired in.
  final Future<void> Function(TeamsEvent event) onEvent;

  /// Records the body of each accepted request, its bytes exactly as they
  /// came, before Teams gets a response and before anything downstream
  /// reads it: in the relay, [recordEvent]. A 200 then means "recorded":
  /// only the writer's `ok` gets one (Nick, 16 Nov). A [RecordFailed],
  /// [RecordRefused] or [RecordUnanswered], or a throw, sends Teams a 500
  /// and forgets the activity was seen, so its retry is taken. None in
  /// tests.
  final Future<RecordAnswer> Function(Uint8List body)? record;

  final Duration bodyTimeout;
  final int maxBodyBytes;

  /// How long an activity is remembered as seen. Teams re-sends after 15
  /// seconds; ten minutes covers its retries with room to spare.
  final Duration seenFor;

  /// A ceiling on the seen set, so a flood cannot grow it without bound.
  final int seenMax;

  final void Function(String line) log;

  final DateTime Function() _now;

  /// Seen key to first sight, oldest first.
  final LinkedHashMap<String, DateTime> _seen = LinkedHashMap();

  Future<void> handle(HttpRequest req) async {
    try {
      if (req.uri.path != path) {
        await _refuseUnread(req, HttpStatus.notFound);
      } else if (req.method != 'POST') {
        await _refuseUnread(req, HttpStatus.methodNotAllowed);
      } else {
        await _messages(req);
      }
    } on Exception catch (e) {
      log('teams relay: $e');
      try {
        await _end(req, HttpStatus.internalServerError);
      } on Exception {
        // The response was already under way; there is no one left to tell.
      }
    }
  }

  Future<void> _messages(HttpRequest req) async {
    if (req.contentLength > maxBodyBytes) {
      return _refuseUnread(req, HttpStatus.requestEntityTooLarge);
    }

    final keySet = await keys.keys();
    if (keySet == null) {
      // Not the sender's fault: no key set has arrived from Microsoft yet.
      // A 503 says "try again", and Teams will.
      log('teams relay: ${HttpStatus.serviceUnavailable} no keys yet');
      return _refuseUnread(req, HttpStatus.serviceUnavailable);
    }

    // The token before the body: a sender with no valid token is turned
    // away at the door, without a byte of its body read.
    final headers = <String, String>{};
    req.headers.forEach((name, values) => headers[name] = values.first);
    final TeamsToken token;
    switch (teamsToken(
      spec: spec,
      keys: keySet,
      headers: headers,
      now: _now(),
    )) {
      case TeamsTokenRefused(:final decision):
        log('teams relay: ${decision.status} ${decision.reason}');
        return _refuseUnread(req, decision.status);
      case final TeamsToken t:
        token = t;
    }

    final body = <int>[];
    var tooLarge = false;
    try {
      // One deadline for the whole body, not a gap between chunks: a sender
      // trickling a byte at a time must not hold the connection open.
      await () async {
        await for (final chunk in req) {
          if (body.length + chunk.length > maxBodyBytes) {
            tooLarge = true;
            return;
          }
          body.addAll(chunk);
        }
      }().timeout(bodyTimeout);
    } on TimeoutException {
      log('teams relay: ${HttpStatus.requestTimeout} body too slow');
      return _refuseUnread(req, HttpStatus.requestTimeout);
    }
    if (tooLarge) return _refuseUnread(req, HttpStatus.requestEntityTooLarge);

    final now = _now();
    // No await from here to _markSeen: two copies of one activity arriving
    // together cannot both get past hasSeen.
    final d = teamsGateBody(
      spec: spec,
      token: token,
      body: body,
      hasSeen: _hasSeen,
      maxBodyBytes: maxBodyBytes,
    );
    if (d.seenKey case final key?) _markSeen(key, now);

    // One line per request, written once its status is decided, so it says
    // what Teams was sent. The reason, never the content: the log is not a
    // copy of anyone's words.
    final line = 'teams relay: ${d.status} ${d.reason}';
    if (d.event != null && record != null) {
      RecordAnswer answer;
      try {
        answer = await record!(Uint8List.fromList(body));
      } on Object catch (e) {
        answer = RecordUnanswered('${e.runtimeType}');
      }
      switch (answer) {
        case Recorded():
          break;
        case RecordFailed(:final why):
          return _unrecorded(req, d, 'record failed partway: $why');
        case RecordRefused(:final why):
          return _unrecorded(req, d, 'refused by the record: $why');
        case RecordUnanswered(:final why):
          return _unrecorded(req, d, 'not recorded: $why');
      }
    }
    log(line);

    req.response.statusCode = d.status;
    if (d.invokeResponse case final body?) {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(body));
    }
    await req.response.close();
    if (d.event case final event?) unawaited(_dispatch(event));
  }

  /// Unrecorded is not taken: forgets [d]'s activity was seen, so the retry
  /// Teams sends for a 500 is taken and recorded then.
  Future<void> _unrecorded(HttpRequest req, TeamsGateDecision d, String why) {
    if (d.seenKey case final key?) _seen.remove(key);
    log('teams relay: ${HttpStatus.internalServerError} ${d.reason}: $why');
    return _end(req, HttpStatus.internalServerError);
  }

  Future<void> _dispatch(TeamsEvent event) async {
    try {
      await onEvent(event);
    } on Exception catch (e) {
      log('teams relay: event handler: $e');
    }
  }

  bool _hasSeen(String key) {
    final at = _seen[key];
    if (at == null) return false;
    if (_now().difference(at) > seenFor) {
      _seen.remove(key);
      return false;
    }
    return true;
  }

  void _markSeen(String key, DateTime at) {
    _seen.remove(key);
    _seen[key] = at;
    while (_seen.length > seenMax) {
      _seen.remove(_seen.keys.first);
    }
    final cutoff = at.subtract(seenFor);
    while (_seen.isNotEmpty && _seen.values.first.isBefore(cutoff)) {
      _seen.remove(_seen.keys.first);
    }
  }

  /// Responds once the whole body has been read.
  static Future<void> _end(HttpRequest req, int status) async {
    req.response.statusCode = status;
    await req.response.close();
  }

  /// Responds with [status] and drops the connection, leaving the rest of
  /// the body unread. dart:io's `response.close()` reads the whole request
  /// body before it sends a byte, so a refusal sent with it would still
  /// wait on whatever the sender chooses to send.
  static Future<void> _refuseUnread(HttpRequest req, int status) async {
    req.response
      ..statusCode = status
      ..persistentConnection = false
      ..contentLength = 0;
    final socket = await req.response.detachSocket();
    await socket.flush();
    socket.destroy();
  }

  static void _stderr(String line) => stderr.writeln(line);

  /// Ids only: which conversation, which activity, what kind. Not the text.
  static Future<void> _logEvent(TeamsEvent event) async {
    stderr.writeln(
      'teams relay: event ${event.runtimeType} '
      '${event.conversation} ${event.id}',
    );
  }
}
