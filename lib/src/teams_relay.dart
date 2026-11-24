/// The HTTP front of the Teams module: the one endpoint Teams posts to.
///
/// It checks the token from the headers alone ([teamsToken]), so a sender
/// with no valid token is refused before its body is read. Then it reads
/// the body under a cap, asks [teamsGateBody], records the body, responds,
/// and only then hands the [TeamsEvent] to [TeamsRelay.onEvent], so nothing
/// done with it can make Teams wait. All of it before the response fits in
/// one [TeamsRelay.budget], inside the 15 seconds after which Teams sends
/// again. It holds no Microsoft credential: the gate needs only the app id
/// and the public keys.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bot_framework_keys.dart';
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
    this.budget = const Duration(seconds: 12),
    this.maxBodyBytes = 1024 * 1024,
    this.log = _stderr,
  }) : _now = now ?? DateTime.now;

  /// Where Teams posts: the Bot Framework's usual messaging path.
  static const path = '/api/messages';

  /// The least a response is given to go out, however little of the budget
  /// is left, so a refusal can still reach the sender.
  static const _leastToAnswer = Duration(milliseconds: 250);

  final TeamsSourceSpec spec;
  final BotFrameworkKeySource keys;

  /// What becomes of an event once Teams has its response. Defaults to a log
  /// line, so the relay runs end to end before a receiver is wired in.
  final Future<void> Function(TeamsEvent event) onEvent;

  /// Records the body of each accepted request, its bytes exactly as they
  /// came, before Teams gets a response and before anything downstream
  /// reads it, given what is left of the [budget]: in the relay,
  /// [recordEvent]. A 200 then means "recorded": only the writer's `ok`
  /// gets one. A [RecordFailed], [RecordRefused] or [RecordUnanswered], a
  /// throw, or no answer within the time given sends Teams a 500, and Teams
  /// sends it again. Every copy Teams sends is recorded, so one activity can
  /// be recorded twice; the docking station decides each event once. None
  /// in tests.
  final Future<RecordAnswer> Function(Uint8List body, Duration within)? record;

  /// The whole time a request has, from its arrival to its response: the
  /// keys, the body and the record. Teams sends a request again when it has
  /// no response after 15 seconds, so this stays under that.
  final Duration budget;

  final int maxBodyBytes;

  final void Function(String line) log;

  final DateTime Function() _now;

  Future<void> handle(HttpRequest req) async {
    final clock = Stopwatch()..start();
    Duration left() {
      final rest = budget - clock.elapsed;
      return rest < _leastToAnswer ? _leastToAnswer : rest;
    }

    try {
      // wire-ok: the HTTP method, checked against the one we accept.
      final isPost = req.method == 'POST';
      if (req.uri.path != path) {
        await _refuseUnread(req, HttpStatus.notFound, left);
      } else if (!isPost) {
        await _refuseUnread(req, HttpStatus.methodNotAllowed, left);
      } else {
        await _messages(req, clock, left);
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

  Future<void> _messages(
    HttpRequest req,
    Stopwatch clock,
    Duration Function() left,
  ) async {
    if (req.contentLength > maxBodyBytes) {
      return _refuseUnread(req, HttpStatus.requestEntityTooLarge, left);
    }

    final BotFrameworkKeys? keySet;
    try {
      keySet = await keys.keys().timeout(budget - clock.elapsed);
    } on TimeoutException {
      log('teams relay: ${HttpStatus.serviceUnavailable} keys too slow');
      return _refuseUnread(req, HttpStatus.serviceUnavailable, left);
    }
    if (keySet == null) {
      // Not the sender's fault: no key set has arrived from Microsoft yet.
      // A 503 says "try again", and Teams will.
      log('teams relay: ${HttpStatus.serviceUnavailable} no keys yet');
      return _refuseUnread(req, HttpStatus.serviceUnavailable, left);
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
        return _refuseUnread(req, decision.status, left);
      case final TeamsToken t:
        token = t;
    }

    final Uint8List body;
    switch (await _read(req, budget - clock.elapsed)) {
      case _TooLarge():
        log('teams relay: ${HttpStatus.requestEntityTooLarge} body over cap');
        return _refuseUnread(req, HttpStatus.requestEntityTooLarge, left);
      case _TooSlow():
        log('teams relay: ${HttpStatus.requestTimeout} body too slow');
        return _refuseUnread(req, HttpStatus.requestTimeout, left);
      case _Broken():
        log('teams relay: ${HttpStatus.badRequest} body broken');
        return _refuseUnread(req, HttpStatus.badRequest, left);
      case _Read(bytes: final b):
        body = b;
    }

    final d = teamsGateBody(
      spec: spec,
      token: token,
      body: body,
      maxBodyBytes: maxBodyBytes,
    );

    // One line per request, written once its status is decided, so it says
    // what Teams was sent. The reason, never the content: the log is not a
    // copy of anyone's words.
    final line = 'teams relay: ${d.status} ${d.reason}';
    if (d.event != null && record != null) {
      final within = budget - clock.elapsed;
      RecordAnswer answer;
      try {
        answer = within <= Duration.zero
            ? const RecordUnanswered('no time left')
            : await record!(body, within).timeout(
                within,
                onTimeout: () => RecordUnanswered(
                  'no answer within ${within.inMilliseconds}ms',
                ),
              );
      } on Object catch (e) {
        answer = RecordUnanswered('${e.runtimeType}');
      }
      switch (answer) {
        case Recorded():
          break;
        case RecordFailed(:final why):
          return _unrecorded(req, d, 'record failed partway: $why');
        case RecordRefused(:final why):
          return _unrecorded(req, d, 'refused by the logbook: $why');
        case RecordUnanswered(:final why):
          return _unrecorded(req, d, 'not recorded: $why');
      }
    }
    log(line);

    req.response
      ..deadline = left()
      ..statusCode = d.status;
    if (d.invokeResponse case final body?) {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(body));
    }
    await req.response.close();
    if (d.event case final event?) unawaited(_dispatch(event));
  }

  Future<void> _unrecorded(HttpRequest req, TeamsGateDecision d, String why) {
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

  /// The body, read until it ends, passes the cap, or [within] runs out.
  Future<_Body> _read(HttpRequest req, Duration within) async {
    if (within <= Duration.zero) return const _TooSlow();
    final builder = BytesBuilder(copy: false);
    final done = Completer<_Body>();
    // One deadline for the whole body, not a gap between chunks: a sender
    // trickling a byte at a time must not hold the connection open.
    final timer = Timer(within, () {
      if (!done.isCompleted) done.complete(const _TooSlow());
    });
    final sub = req.listen(
      (chunk) {
        if (builder.length + chunk.length > maxBodyBytes) {
          if (!done.isCompleted) done.complete(const _TooLarge());
          return;
        }
        builder.add(chunk);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(_Read(builder.takeBytes()));
      },
      onError: (Object e) {
        if (!done.isCompleted) done.complete(const _Broken());
      },
    );
    final body = await done.future;
    timer.cancel();
    // Paused, not cancelled: cancelling the body detaches dart:io's request
    // from its response, and the refusal then can't take the socket to drop
    // it. Destroying the socket ends the subscription.
    if (body is! _Read) sub.pause();
    return body;
  }

  /// Responds once the whole body has been read.
  static Future<void> _end(HttpRequest req, int status) async {
    req.response.statusCode = status;
    await req.response.close();
  }

  /// Responds with [status] and drops the connection, leaving the rest of
  /// the body unread. dart:io's `response.close()` reads the whole request
  /// body before it sends a byte, so a refusal sent with it would still
  /// wait on whatever the sender chooses to send. The flush gets what is
  /// left of the budget, and the socket is destroyed whatever it does.
  static Future<void> _refuseUnread(
    HttpRequest req,
    int status,
    Duration Function() left,
  ) async {
    req.response
      ..statusCode = status
      ..persistentConnection = false
      ..contentLength = 0;
    final socket = await req.response.detachSocket();
    try {
      await socket.flush().timeout(left());
    } on TimeoutException {
      // The sender isn't reading; it gets no response, as if dropped.
    } finally {
      socket.destroy();
    }
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

/// How reading a request's body ended.
sealed class _Body {
  const _Body();
}

final class _Read extends _Body {
  const _Read(this.bytes);
  final Uint8List bytes;
}

final class _TooLarge extends _Body {
  const _TooLarge();
}

final class _TooSlow extends _Body {
  const _TooSlow();
}

/// The connection failed or closed before the body ended.
final class _Broken extends _Body {
  const _Broken();
}
