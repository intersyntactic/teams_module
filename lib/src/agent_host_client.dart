import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checked_json/checked_json.dart';
import 'package:intersyntactic_protocol/intersyntactic_protocol.dart'
    show
        AgentRoute,
        JourneyPathFrame,
        JourneyPathId,
        JourneyPathList,
        JourneyPathMessageRoute,
        JourneyPathStopRoute,
        JourneyPathStreamEvent,
        JourneyPathStreamRoute,
        JourneyPathSummary,
        ListJourneyPathsRoute,
        LoggedEvent,
        RepoChoice,
        RepoList,
        ReposRoute,
        SendMessage,
        StartJourneyPath,
        StartJourneyPathRoute;

import 'bot_connector.dart' show HttpCall, HttpResult, httpCall;

/// What the bridge needs of intersyntactic's agent host: the journeys it
/// holds, what happens in one as it happens, and the person's messages into
/// one. A journey holds one or more journey paths, and what is said, stopped
/// or read is said, stopped or read on one of them.
abstract interface class Journeys {
  /// Every journey the host holds, and every journey path in them.
  Future<JourneyPathList> list();

  /// Sends [text] into [journey] as the person's message. Null when it was
  /// taken, else the host's refusal, whose body is for the log only.
  Future<HostError?> say(JourneyPathId journey, String text);

  /// Stops the turn [journey] is running. Null when stopped, else the host's
  /// refusal.
  Future<HostError?> stop(JourneyPathId journey);

  /// The repos a journey can start in, the most recently used first.
  Future<List<RepoChoice>> repos();

  /// Starts a journey: the new one, or the host's refusal.
  Future<({JourneyPathSummary? started, HostError? why})> start(
    StartJourneyPath run,
  );

  /// Every event of [journey] after the one at seq [after], which happened
  /// [afterAt], then each as it happens. It ends when the connection does.
  ///
  /// The host trusts [after] only when its own event there happened
  /// [afterAt]: a restart can renumber its log. Otherwise it sends every
  /// event from the first, so a reader must skip what it has seen by time.
  Stream<LoggedEvent> events(
    JourneyPathId journey, {
    required int after,
    required DateTime? afterAt,
  });
}

/// The host answered [route] with [status], not 200. Its [body] is for the
/// log only: it is the host's own text, unbounded, and nothing in the record
/// holds it, so it never goes to a chat.
final class HostError implements Exception {
  const HostError(this.route, this.status, [this.body = '']);

  /// Which call it was, such as `list`.
  final String route;
  final int status;
  final String body;

  @override
  String toString() => 'HostError: $route: $status $body';
}

/// [Journeys] over HTTP, from the host's own machine: the host listens on
/// loopback, and asks nothing of a caller there.
final class AgentHostClient implements Journeys {
  AgentHostClient(this.base, {HttpCall? http}) : _call = http ?? httpCall;

  /// Where the host listens, such as `http://127.0.0.1:8899`.
  final Uri base;
  final HttpCall _call;

  Future<HttpResult> _send(AgentRoute route, [Object? body]) => _call(
    route.method.wire,
    route.uri(base),
    {'content-type': 'application/json; charset=utf-8'},
    body == null ? '' : jsonEncode(body),
  );

  @override
  Future<JourneyPathList> list() async {
    final r = await _send(const ListJourneyPathsRoute());
    if (r.status != 200) throw HostError('list', r.status, r.body);
    return JourneyPathList.fromJson(JsonObject.decode(r.body));
  }

  @override
  Future<HostError?> say(JourneyPathId journey, String text) async {
    final r = await _send(
      JourneyPathMessageRoute(journey),
      SendMessage(text).toJson(),
    );
    return r.status == 200
        ? null
        : HostError('message', r.status, _reason(r.body));
  }

  @override
  Future<HostError?> stop(JourneyPathId journey) async {
    final r = await _send(JourneyPathStopRoute(journey));
    return r.status == 200
        ? null
        : HostError('stop', r.status, _reason(r.body));
  }

  @override
  Future<List<RepoChoice>> repos() async {
    final r = await _send(const ReposRoute());
    if (r.status != 200) throw HostError('repos', r.status, r.body);
    return RepoList.fromJson(JsonObject.decode(r.body)).repos;
  }

  @override
  Future<({JourneyPathSummary? started, HostError? why})> start(
    StartJourneyPath run,
  ) async {
    final r = await _send(const StartJourneyPathRoute(), run.toJson());
    return r.status == 200
        ? (
            started: JourneyPathSummary.fromJson(JsonObject.decode(r.body)),
            why: null,
          )
        : (started: null, why: HostError('start', r.status, _reason(r.body)));
  }

  /// Cancelling closes the connection at once. A generator here (`async*`)
  /// could not: parked on a quiet journey's socket, it stays deaf to a cancel
  /// until the next event arrives, and a journey can be quiet for hours.
  @override
  Stream<LoggedEvent> events(
    JourneyPathId journey, {
    required int after,
    required DateTime? afterAt,
  }) {
    final client = HttpClient();
    StreamSubscription<({String event, String data})>? frames;
    late final StreamController<LoggedEvent> out;
    out = StreamController<LoggedEvent>(
      onListen: () async {
        try {
          final req = await client.getUrl(
            JourneyPathStreamRoute(
              journey,
              after: after,
              afterAt: afterAt,
            ).uri(base),
          );
          req.headers.set('accept', 'text/event-stream');
          final res = await req.close();
          if (res.statusCode != 200) {
            throw HostError('events', res.statusCode);
          }
          frames = serverSentEvents(res).listen(
            (f) {
              final kind = JourneyPathStreamEvent.parse(f.event);
              if (kind != JourneyPathStreamEvent.agent) return;
              out.add(
                JourneyPathFrame.fromJson(JsonObject.decode(f.data)).event,
              );
            },
            onError: out.addError,
            onDone: out.close,
          );
        } on Exception catch (e) {
          out.addError(e);
          await out.close();
        }
      },
      onCancel: () {
        client.close(force: true);
        return frames?.cancel();
      },
    );
    return out.stream;
  }

  /// The host's `{"error": ...}`, or the body whole when it is not that.
  static String _reason(String body) {
    try {
      return JsonObject.decode(body).stringOrNull('error') ?? body;
    } on FormatException {
      return body;
    }
  }
}

/// Server-sent events from [bytes]: each `event:` name with its `data:`
/// lines joined, dispatched at a blank line. A comment (`: ...`) is skipped,
/// and an event with no `event:` line is named `message`, as the format says
/// (https://html.spec.whatwg.org/multipage/server-sent-events.html).
Stream<({String event, String data})> serverSentEvents(
  Stream<List<int>> bytes,
) async* {
  var event = '';
  final data = <String>[];
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        yield (event: event.isEmpty ? 'message' : event, data: data.join('\n'));
      }
      event = '';
      data.clear();
    } else if (line.startsWith(':')) {
      continue;
    } else {
      final colon = line.indexOf(':');
      final field = colon < 0 ? line : line.substring(0, colon);
      var value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'event':
          event = value;
        case 'data':
          data.add(value);
      }
    }
  }
}
