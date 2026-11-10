import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checked_json/checked_json.dart';
import 'package:intersyntactic_protocol/intersyntactic_protocol.dart'
    show
        AgentRoute,
        ListRunsRoute,
        LoggedEvent,
        RunFrame,
        RunId,
        RunList,
        RunMessageRoute,
        RunStopRoute,
        RunStreamEvent,
        RunStreamRoute,
        RunSummary,
        SendMessage;

import 'bot_connector.dart' show HttpCall, HttpResult, httpCall;

/// What the bridge needs of intersyntactic's agent host: the journeys it
/// holds, what happens in one as it happens, and the person's messages into
/// one. The protocol still names a journey a run (`RunId`, `RunSummary`); the
/// words here are RULINGS'.
abstract interface class Journeys {
  /// Every journey the host holds.
  Future<List<RunSummary>> list();

  /// Sends [text] into [journey] as the person's message. Null when it was
  /// taken, else the host's reason, such as that a turn is still running.
  Future<String?> say(RunId journey, String text);

  /// Stops the turn [journey] is running. Null when stopped, else the host's
  /// reason.
  Future<String?> stop(RunId journey);

  /// Every event of [journey] after the one at seq [after], which happened
  /// [afterAt], then each as it happens. It ends when the connection does.
  ///
  /// The host trusts [after] only when its own event there happened
  /// [afterAt]: a restart can renumber its log. Otherwise it sends every
  /// event from the first, so a reader must skip what it has seen by time.
  Stream<LoggedEvent> events(
    RunId journey, {
    required int after,
    required DateTime? afterAt,
  });
}

/// [Journeys] over HTTP, from the host's own machine: the host listens on
/// loopback, and asks nothing of a caller there.
final class AgentHostClient implements Journeys {
  AgentHostClient(this.base, {HttpCall? http}) : _call = http ?? httpCall;

  /// Where the host listens, such as `http://127.0.0.1:8900`.
  final Uri base;
  final HttpCall _call;

  Future<HttpResult> _send(AgentRoute route, [Object? body]) => _call(
    route.method.wire,
    route.uri(base),
    {'content-type': 'application/json; charset=utf-8'},
    body == null ? '' : jsonEncode(body),
  );

  @override
  Future<List<RunSummary>> list() async {
    final r = await _send(const ListRunsRoute());
    if (r.status != 200) throw HttpException('list: ${r.status} ${r.body}');
    return RunList.fromJson(JsonObject.decode(r.body)).runs;
  }

  @override
  Future<String?> say(RunId journey, String text) async {
    final r = await _send(RunMessageRoute(journey), SendMessage(text).toJson());
    return r.status == 200 ? null : _reason(r.body);
  }

  @override
  Future<String?> stop(RunId journey) async {
    final r = await _send(RunStopRoute(journey));
    return r.status == 200 ? null : _reason(r.body);
  }

  /// Cancelling closes the connection at once. A generator here (`async*`)
  /// could not: parked on a quiet journey's socket, it stays deaf to a cancel
  /// until the next event arrives, and a journey can be quiet for hours.
  @override
  Stream<LoggedEvent> events(
    RunId journey, {
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
            RunStreamRoute(journey, after: after, afterAt: afterAt).uri(base),
          );
          req.headers.set('accept', 'text/event-stream');
          final res = await req.close();
          if (res.statusCode != 200) {
            throw HttpException('events: ${res.statusCode}');
          }
          frames = serverSentEvents(res).listen(
            (f) {
              if (RunStreamEvent.parse(f.event) != RunStreamEvent.agent) return;
              out.add(RunFrame.fromJson(JsonObject.decode(f.data)).event);
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
