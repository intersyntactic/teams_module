import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checked_json/checked_json.dart';
import 'package:intersyntactic_protocol/intersyntactic_protocol.dart'
    show
        JourneyId,
        JourneyPathFrame,
        JourneyPathId,
        JourneyPathList,
        JourneyPathSummary,
        JourneySummary,
        LoggedEvent,
        ReplyText;
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

final journey = JourneySummary.fromJson(
  JsonObject.of({
    'id': 'abcde12345',
    'number': 242,
    'name': 'teams-bridge',
    'ended': false,
    'tasks': <Object?>[],
  }),
);

final summary = JourneyPathSummary.fromJson(
  JsonObject.of({
    'id': 'j1',
    'journey': 'abcde12345',
    'provider': 'anthropic',
    'model': 'claude-opus-5-5',
    'state': 'idle',
    'events': 3,
    'task': 'a task',
    'started_at': '2026-11-10T00:00:00Z',
    'last_active_at': '2026-11-10T00:00:00Z',
    'messages': 1,
    'continuable': true,
    'awaiting': false,
  }),
);

void main() {
  late HttpServer host;
  late AgentHostClient client;
  late List<(String, String, String)> requests;

  /// Answers each request with [answer], given its method, path and body.
  void answering(
    FutureOr<void> Function(HttpRequest req, String body) answer,
  ) => host.listen((req) async {
    final body = await utf8.decodeStream(req);
    requests.add((req.method, req.uri.toString(), body));
    await answer(req, body);
  });

  setUp(() async {
    requests = [];
    host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = AgentHostClient(Uri.parse('http://127.0.0.1:${host.port}'));
  });
  tearDown(() => host.close(force: true));

  test('lists the journeys the host holds, and their journey paths', () async {
    answering((req, _) async {
      req.response.write(
        jsonEncode(JourneyPathList([journey], [summary]).toJson()),
      );
      await req.response.close();
    });
    final listed = await client.list();
    expect(listed.journeys.single.name?.value, 'teams-bridge');
    expect(listed.journeyPaths.single.id, JourneyPathId('j1'));
    expect(listed.journeyPaths.single.journey, JourneyId.parse('abcde12345'));
    expect(requests.single.$2, '/agent');
  });

  test('says a message into a journey', () async {
    answering((req, _) async {
      req.response.write('{}');
      await req.response.close();
    });
    expect(await client.say(JourneyPathId('j1'), 'hello'), isNull);
    final (method, path, body) = requests.single;
    expect((method, path), ('POST', '/agent/j1/message'));
    expect(jsonDecode(body), {'text': 'hello'});
  });

  test("passes on the host's reason for refusing", () async {
    answering((req, _) async {
      req.response
        ..statusCode = 409
        ..write('{"error":"still working"}');
      await req.response.close();
    });
    expect(await client.say(JourneyPathId('j1'), 'hello'), 'still working');
  });

  group('events', () {
    /// A host that sends one frame of each kind, then goes quiet and stays
    /// open, as a journey between turns does.
    void quietAfter(LoggedEvent e) => answering((req, _) async {
      // Sent as written, as the host sends its stream: a buffered response
      // holds a small frame back, flush or not.
      req.response.bufferOutput = false;
      req.response.headers.contentType = ContentType('text', 'event-stream');
      req.response
        ..write(': connected\n\n')
        ..write('event: output\ndata: {"id":"c1","line":"building"}\n\n')
        ..write(
          'event: agent\ndata: ${jsonEncode(JourneyPathFrame(summary, e).toJson())}\n\n',
        );
      await req.response.flush();
    });

    final at = DateTime.utc(2026, 11, 10, 7, 55, 36, 123, 456);

    test("reads the journey's events, and only those", () async {
      quietAfter(LoggedEvent(3, const ReplyText('hi')));
      final first = await client
          .events(JourneyPathId('j1'), after: 2, afterAt: at)
          .first;
      expect(first.seq, 3);
      expect(first.event, isA<ReplyText>());
      expect(Uri.parse(requests.single.$2).queryParameters, {
        'after': '2',
        'after_at': at.toIso8601String(),
      });
    });

    test('stop at once when cancelled, though the host is quiet', () async {
      quietAfter(LoggedEvent(3, const ReplyText('hi')));
      final got = Completer<void>();
      final sub = client
          .events(JourneyPathId('j1'), after: 2, afterAt: at)
          .listen((_) => got.complete());
      await got.future;
      await sub.cancel().timeout(const Duration(seconds: 2));
    });

    test(
      'stop at once when cancelled, though the host never answers',
      () async {
        // It takes the request and says nothing, not even its headers.
        final asked = Completer<void>();
        host.listen((_) => asked.complete());
        final sub = client
            .events(JourneyPathId('j1'), after: 2, afterAt: at)
            .listen((_) {}, onError: (_) {});
        await asked.future;
        await sub.cancel().timeout(const Duration(seconds: 2));
      },
    );
  });
}
