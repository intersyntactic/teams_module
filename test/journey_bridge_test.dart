import 'dart:async';
import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:intersyntactic_protocol/intersyntactic_protocol.dart'
    show
        BranchName,
        JourneyState,
        LandsIn,
        LoggedEvent,
        MergeAnswered,
        MergeAsked,
        MergeMethod,
        ReplyText,
        RunEvent,
        RunId,
        RunSummary,
        StatusChanged,
        ToolAsked,
        ToolName,
        UserSaid;
import 'package:is_shapes/is_shapes.dart' show ActorId;
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

const tenant = '09e0393f-03f1-4206-84f3-8b127b750a5d';
const nick = 'cccccccc-0000-4000-8000-000000000003';
const peter = 'aaaaaaaa-0000-4000-8000-000000000001';
const chat = 'a:nick';
final serviceUrl = Uri.parse('https://smba.trafficmanager.net/au/');
final owner = ActorId.parse('teams:$tenant/$nick')!;

RunSummary journey(
  String id, {
  JourneyState state = JourneyState.idle,
  int events = 5,
  String? name,
  bool awaiting = false,
  DateTime? lastActiveAt,
}) => RunSummary.fromJson(
  JsonObject.of({
    'id': id,
    'provider': 'anthropic',
    'model': 'claude-opus-5-5',
    'state': state.name,
    'events': events,
    'task': 'Task of $id\nmore lines',
    'started_at': '2026-11-10T00:00:00Z',
    'last_active_at': (lastActiveAt ?? lastActive).toIso8601String(),
    'messages': 1,
    'name': ?name,
    'continuable': true,
    'awaiting': awaiting,
  }),
);

/// An agent host in memory: its journeys, what was said and stopped, and a
/// stream of events per reading that the test feeds by hand.
final class FakeJourneys implements Journeys {
  final listed = <RunSummary>[];
  final said = <(RunId, String)>[];
  final stopped = <RunId>[];
  final streams =
      <
        ({
          RunId journey,
          int after,
          DateTime? afterAt,
          StreamController<LoggedEvent> events,
        })
      >[];
  String? refuse;

  @override
  Future<List<RunSummary>> list() async => listed;

  @override
  Future<String?> say(RunId journey, String text) async {
    if (refuse != null) return refuse;
    said.add((journey, text));
    return null;
  }

  @override
  Future<String?> stop(RunId journey) async {
    stopped.add(journey);
    return null;
  }

  @override
  Stream<LoggedEvent> events(
    RunId journey, {
    required int after,
    required DateTime? afterAt,
  }) {
    final c = StreamController<LoggedEvent>();
    streams.add((journey: journey, after: after, afterAt: afterAt, events: c));
    return c.stream;
  }

  /// Feeds [events] into the newest stream, numbered on from [from], each a
  /// second after the one before it from [lastActive]'s next second.
  Future<void> feed(
    int from,
    List<RunEvent> events, {
    DateTime Function(int seq) at = when,
  }) async {
    final c = streams.last.events;
    for (final (i, e) in events.indexed) {
      c.add(LoggedEvent(from + i, e, at: at(from + i)));
    }
    await pump();
  }
}

/// When every journey in these tests last did something.
final lastActive = DateTime.utc(2026, 11, 10);

/// When the event at [seq] happened: after [lastActive] for a seq past the
/// summaries' 7 events, before it for one of those.
DateTime when(int seq) => lastActive.add(Duration(seconds: seq - 6));

/// Lets queued events and sends run.
Future<void> pump() =>
    Future<void>.delayed(Duration.zero)
        .then((_) => Future<void>.delayed(Duration.zero));

void main() {
  late FakeJourneys host;
  late JourneyBridge bridge;
  late List<Map<String, Object?>> sent;
  late List<String> ids;
  late List<(String, Map<String, Object?>)> updated;
  late List<String> logged;
  var nextId = 0;

  JourneyBridge bridgeFor(ActorId? who) => JourneyBridge(
    journeys: host,
    owner: who,
    send: (url, conversation, activity) async {
      sent.add(activity);
      ids.add('act-${nextId++}');
      return ids.last;
    },
    update: (url, conversation, id, activity) async =>
        updated.add((id, activity)),
    log: logged.add,
    retryAfter: const Duration(milliseconds: 10),
    typingEvery: Duration.zero,
  );

  setUp(() {
    host = FakeJourneys();
    sent = [];
    ids = [];
    updated = [];
    logged = [];
    nextId = 0;
    bridge = bridgeFor(owner);
  });
  tearDown(() => bridge.close());

  JsonObject message(String text, {String user = nick}) => JsonObject.of({
    'event': 'teams_message',
    'tenant': tenant,
    'conversation': chat,
    'service_url': '$serviceUrl',
    'from_aad_object_id': user,
    'text': text,
  });

  JsonObject press(
    String verb, {
    String card = 'card',
    String? journey,
    String user = nick,
  }) => JsonObject.of({
    'event': 'teams_card_action',
    'tenant': tenant,
    'conversation': chat,
    'service_url': '$serviceUrl',
    'from_aad_object_id': user,
    'reply_to': card,
    'value': {
      'action': {
        'verb': verb,
        'data': {'journey': ?journey},
      },
    },
  });

  String textOf(Map<String, Object?> activity) => activity['text']! as String;
  String cardOf(Map<String, Object?> activity) => jsonEncode(activity);

  /// Opens journey `j1` in this chat.
  Future<void> opened() async {
    host.listed.add(journey('j1', events: 7, name: 'teams-bridge'));
    await bridge.onDoorbell(press('open', journey: 'j1'));
    sent.clear();
  }

  group('who it answers', () {
    test('someone else is told no, and nothing reaches a journey', () async {
      await opened();
      await bridge.onDoorbell(message('rm -rf ~', user: peter));
      expect(host.said, isEmpty);
      expect(textOf(sent.single), contains('only its owner'));
      expect(logged.single, contains('teams:$tenant/$peter'));
    });

    test("someone else's press reaches nothing either", () async {
      await opened();
      await bridge.onDoorbell(press('yes', user: peter));
      expect(host.said, isEmpty);
      expect(sent, isEmpty);
    });

    test('with no owner, it says how to make the sender one', () async {
      bridge = bridgeFor(null);
      await bridge.onDoorbell(message('hello'));
      expect(textOf(sent.single), contains('TEAMS_OWNER=teams:$tenant/$nick'));
      expect(host.said, isEmpty);
    });
  });

  group('picking a journey', () {
    test('"journeys" offers the active ones, newest first', () async {
      host.listed.addAll([
        journey('old', lastActiveAt: DateTime.utc(2026, 11, 1)),
        journey('done', state: JourneyState.ended),
        journey('new', name: 'newest', lastActiveAt: DateTime.utc(2026, 11, 9)),
      ]);
      await bridge.onDoorbell(message('journeys'));
      final card = cardOf(sent.single);
      expect(card, isNot(contains('"done"')));
      expect(card.indexOf('newest'), lessThan(card.indexOf('Task of old')));
      expect(card, contains('"journey":"new"'));
    });

    test('Open reads it from its newest event', () async {
      await opened();
      expect(bridge.openIn(chat), RunId('j1'));
      expect(host.streams.single.after, 6);
      expect(host.streams.single.afterAt, lastActive);
    });

    test('a journey that has ended is not opened', () async {
      host.listed.add(journey('j1', state: JourneyState.ended));
      await bridge.onDoorbell(press('open', journey: 'j1'));
      expect(bridge.openIn(chat), isNull);
      expect(textOf(sent.single), contains('has ended'));
    });

    test('a message with no journey open says how to open one', () async {
      await bridge.onDoorbell(message('hello'));
      expect(textOf(sent.single), contains('journeys'));
      expect(host.said, isEmpty);
    });
  });

  group('talking into it', () {
    test('a message is said into the journey open', () async {
      await opened();
      await bridge.onDoorbell(message('add a test'));
      expect(host.said.single, (RunId('j1'), 'add a test'));
    });

    test("the host's refusal is passed on", () async {
      await opened();
      host.refuse = 'still working -- wait for it to finish, or stop it';
      await bridge.onDoorbell(message('and another thing'));
      expect(textOf(sent.single), contains('Not sent: still working'));
    });

    test('"stop" stops it', () async {
      await opened();
      await bridge.onDoorbell(message('stop'));
      expect(host.stopped.single, RunId('j1'));
    });
  });

  group('what it shows', () {
    test('a turn is one message, sent when it ends', () async {
      await opened();
      await bridge.onDoorbell(message('add a test'));
      await host.feed(7, [
        const UserSaid('add a test'),
        const StatusChanged(JourneyState.running),
        const ReplyText('Added '),
        const ReplyText('one.'),
      ]);
      expect(sent.where((a) => a['type'] == 'message'), isEmpty);
      await host.feed(11, [const StatusChanged(JourneyState.idle)]);
      final messages = sent.where((a) => a['type'] == 'message').toList();
      expect(messages.map(textOf), ['Added one.']);
      expect(sent.where((a) => a['type'] == 'typing'), isNotEmpty);
    });

    test(
      'what was said in the app is shown, and its own echo is not',
      () async {
        await opened();
        await bridge.onDoorbell(message('from teams'));
        await host.feed(7, [
          const UserSaid('from teams'),
          const UserSaid('from the app'),
        ]);
        expect(sent.map(textOf), ['_Said in the app:_ from the app']);
      },
    );

    test('a failed turn says so, after what it had replied', () async {
      await opened();
      await host.feed(7, [
        const ReplyText('Half'),
        const StatusChanged(JourneyState.failed, detail: 'overloaded'),
      ]);
      expect(sent.map(textOf), ['Half', 'It failed: overloaded']);
    });
  });

  group('questions', () {
    const merge = MergeAsked(
      number: 42,
      base: BranchName('release'),
      landsIn: LandsIn.defaultBranch,
      method: MergeMethod.squash,
    );

    test(
      'a question is a card with Yes and No, after the reply so far',
      () async {
        await opened();
        await host.feed(7, [const ReplyText('Ready.'), merge]);
        expect(textOf(sent.first), 'Ready.');
        final card = cardOf(sent.last);
        expect(card, contains('Merge PR #42 into release?'));
        expect(card, contains('"verb":"yes"'));
        expect(card, contains('"verb":"no"'));
      },
    );

    test('Yes on its card is the person\'s 1, and No their 2', () async {
      await opened();
      await host.feed(7, [merge]);
      final card = ids.last;
      await bridge.onDoorbell(press('yes', card: card));
      await bridge.onDoorbell(press('no', card: card));
      expect(host.said.map((s) => s.$2), ['1', '2']);
    });

    test('Yes on any other card says nothing into the journey', () async {
      await opened();
      await host.feed(7, [merge]);
      await bridge.onDoorbell(press('yes', card: 'an-old-card'));
      expect(host.said, isEmpty);
    });

    test('once answered, its card says how and offers nothing more', () async {
      await opened();
      await host.feed(7, [merge]);
      final card = ids.last;
      await host.feed(8, [const MergeAnswered(ask: 7, approved: true)]);
      final (id, activity) = updated.single;
      expect(id, card);
      expect(cardOf(activity), contains('Yes.'));
      expect(cardOf(activity), isNot(contains('"verb"')));
      await bridge.onDoorbell(press('yes', card: card));
      expect(host.said, isEmpty);
    });

    test("a tool's question shows its input as code", () async {
      await opened();
      await host.feed(7, [
        ToolAsked(
          tool: const ToolName('git_push'),
          input: JsonObject.of({'force': true}),
        ),
      ]);
      final card = cardOf(sent.single);
      expect(card, contains('Run git_push?'));
      expect(card, contains('Monospace'));
      expect(card, contains(r'{\"force\":true}'));
    });
  });

  test('when its events stop, it reads on from the last one', () async {
    await opened();
    await host.feed(7, [const ReplyText('a'), const ReplyText('b')]);
    await host.streams.last.events.close();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(host.streams, hasLength(2));
    expect(host.streams.last.after, 8);
    expect(host.streams.last.afterAt, when(8));
  });

  test(
    'a host that sends its whole log again shows none of it twice',
    () async {
      await opened();
      // What a host sends when it cannot resume: everything, from the first,
      // and here renumbered, as after a restart.
      await host.feed(0, [
        const ReplyText('an old reply'),
        const StatusChanged(JourneyState.idle),
      ]);
      expect(sent, isEmpty);
      await host.feed(7, [
        const ReplyText('new'),
        const StatusChanged(JourneyState.idle),
      ]);
      expect(sent.map(textOf), ['new']);
      // And again, from the top, once it has moved on.
      await host.feed(0, [
        const ReplyText('older still'),
        const StatusChanged(JourneyState.idle),
      ]);
      expect(sent.map(textOf), ['new']);
    },
  );

  test('two events stamped with one moment are both shown', () async {
    await opened();
    final moment = when(7);
    await host.feed(7, [
      const ReplyText('one '),
      const ReplyText('moment'),
      const StatusChanged(JourneyState.idle),
    ], at: (_) => moment);
    expect(sent.map(textOf), ['one moment']);
  });

  test(
    'after a restart renumbers the log, a new event is still shown',
    () async {
      await opened();
      await host.feed(7, [
        const ReplyText('before'),
        const StatusChanged(JourneyState.idle),
      ]);
      // The restart lost events 7 and 8 from its log, so the next one it
      // writes takes seq 7 again: a seq already seen, at a time not yet seen.
      await host.feed(7, [
        const ReplyText('after'),
        const StatusChanged(JourneyState.idle),
      ], at: (seq) => when(seq).add(const Duration(hours: 1)));
      expect(sent.map(textOf), ['before', 'after']);
    },
  );

  group('splitting for Teams', () {
    test('leaves a short text whole', () {
      expect(splitForTeams('short'), ['short']);
    });

    test('cuts a long one at a paragraph in its second half', () {
      final text = '${'a' * 70}\n\n${'b' * 50}';
      expect(splitForTeams(text, max: 100), ['a' * 70, 'b' * 50]);
    });

    test('cuts hard when no paragraph falls in the second half', () {
      final text = 'a' * 250;
      expect(splitForTeams(text, max: 100), ['a' * 100, 'a' * 100, 'a' * 50]);
    });
  });

  group('server-sent events', () {
    Future<List<({String event, String data})>> read(String s) =>
        serverSentEvents(Stream.value(utf8.encode(s))).toList();

    test('names each event and joins its data lines', () async {
      expect(
        await read(': connected\n\nevent: agent\ndata: {"a":\ndata: 1}\n\n'),
        [(event: 'agent', data: '{"a":\n1}')],
      );
    });

    test('an event with no name is a message', () async {
      expect(await read('data: x\r\n\r\n'), [(event: 'message', data: 'x')]);
    });

    test('an event not yet ended by a blank line is not dispatched', () async {
      expect(await read('event: agent\ndata: x\n'), isEmpty);
    });
  });
}
