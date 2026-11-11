import 'dart:async';
import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:intersyntactic_protocol/intersyntactic_protocol.dart'
    show
        BranchName,
        JourneyPathEvent,
        JourneyPathId,
        JourneyPathSummary,
        JourneyState,
        LandsIn,
        LoggedEvent,
        MergeAnswered,
        MergeAsked,
        MergeMethod,
        Provider,
        ReplyText,
        RepoChoice,
        RepoPath,
        StartJourneyPath,
        StatusChanged,
        ThinkingText,
        ToolAsked,
        ToolCalled,
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

JourneyPathSummary journey(
  String id, {
  JourneyState state = JourneyState.idle,
  int events = 5,
  String? name,
  bool awaiting = false,
  DateTime? lastActiveAt,
  String provider = 'anthropic',
  String model = 'claude-opus-5-5',
}) => JourneyPathSummary.fromJson(
  JsonObject.of({
    'id': id,
    'provider': provider,
    'model': model,
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
  final listed = <JourneyPathSummary>[];
  final said = <(JourneyPathId, String)>[];
  final stopped = <JourneyPathId>[];
  final streams =
      <
        ({
          JourneyPathId journey,
          int after,
          DateTime? afterAt,
          StreamController<LoggedEvent> events,
        })
      >[];
  String? refuse;

  /// What a list that cannot be read throws, as a host on another wire does.
  Exception? unreadable;

  /// Echoes what is said, numbered [echoAt], before answering, as the live
  /// host does when its event stream wins the race with its answer.
  int? echoAt;

  @override
  Future<List<JourneyPathSummary>> list() async {
    if (unreadable case final e?) throw e;
    return listed;
  }

  @override
  Future<String?> say(JourneyPathId journey, String text) async {
    if (refuse != null) return refuse;
    said.add((journey, text));
    if (echoAt case final seq?) await feed(seq, [UserSaid(text)]);
    return null;
  }

  @override
  Future<String?> stop(JourneyPathId journey) async {
    stopped.add(journey);
    return null;
  }

  final repoChoices = <RepoChoice>[];
  final starts = <StartJourneyPath>[];

  /// The journey a start makes, or with [refuse] set, none.
  JourneyPathSummary? starting;

  @override
  Future<List<RepoChoice>> repos() async => repoChoices;

  @override
  Future<({JourneyPathSummary? started, String? why})> start(
    StartJourneyPath run,
  ) async {
    starts.add(run);
    if (refuse != null) return (started: null, why: refuse);
    return (started: starting, why: null);
  }

  @override
  Stream<LoggedEvent> events(
    JourneyPathId journey, {
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
    List<JourneyPathEvent> events, {
    DateTime Function(int seq) at = when,
  }) async {
    final c = streams.last.events;
    for (final (i, e) in events.indexed) {
      c.add(LoggedEvent(from + i, e, at: at(from + i)));
    }
    await pump();
  }
}

/// Teams' side of a stream, as Microsoft documents it
/// (https://learn.microsoft.com/en-us/microsoftteams/platform/bots/streaming-ux):
/// a typing activity numbered 1 starts one and is answered with its id;
/// updates are numbered on, and one out of order is dropped; a final message,
/// with no number, ends it; and a stream takes a request only [every] so
/// often. What it refuses it throws, as the Connector does.
final class FakeTeams {
  FakeTeams({this.every = Duration.zero});

  final Duration every;

  /// Everything posted, as it was posted.
  final posted = <Map<String, Object?>>[];

  /// What each stream showed of what the journey was doing, the text it grew
  /// as the reply was written, and the final message that ended it.
  final shown = <String, List<String>>{};
  final written = <String, List<String>>{};
  final finals = <String, String>{};

  /// Informative updates sent once a stream had text: taken, never shown.
  final hidden = <String>[];

  /// Refuses every request on a stream, as Teams does where streaming is
  /// not allowed.
  String? refuse;

  /// Refuses a final message, as Teams does once a stream has timed out.
  bool refuseFinal = false;

  final _last = <String, ({int sequence, DateTime at})>{};

  Future<String?> post(
    Uri serviceUrl,
    String conversation,
    Map<String, Object?> activity,
  ) async {
    posted.add(activity);
    final info = (activity['entities'] as List<Object?>?)
        ?.cast<Map<String, Object?>>()
        .where((e) => e['type'] == 'streaminfo')
        .firstOrNull;
    if (info == null) return null;
    BotConnectorException no(int status, String why) =>
        BotConnectorException('post', status, why);
    if (refuse != null) throw no(403, refuse!);
    if (activity['replyToId'] == null) throw no(400, 'no replyToId');
    final now = DateTime.now();
    final id = info['streamId'] as String?;
    if (id == null) {
      if (activity['type'] != 'typing' ||
          !const {'informative', 'streaming'}.contains(info['streamType']) ||
          info['streamSequence'] != 1 ||
          '${activity['text'] ?? ''}'.isEmpty) {
        throw no(400, 'not a start: $activity');
      }
      if (shown.keys.any((s) => !finals.containsKey(s))) {
        throw no(403, 'a stream is already open in this conversation');
      }
      final started = 'stream-${shown.length}';
      shown[started] = [];
      written[started] = [];
      _take(started, info, activity);
      _last[started] = (sequence: 1, at: now);
      return started;
    }
    final last = _last[id] ?? (throw no(400, 'no stream $id'));
    if (finals.containsKey(id)) {
      throw no(
        403,
        'Content stream is not allowed on an already completed '
        'streamed message',
      );
    }
    // A little slack: the bridge's clock reads a moment before this one.
    if (now.difference(last.at) < every * 0.9) {
      throw no(429, 'API calls quota exceeded');
    }
    if (info['streamType'] == 'final') {
      if (activity['type'] != 'message' || info.containsKey('streamSequence')) {
        throw no(400, 'not a final: $activity');
      }
      if (refuseFinal) {
        throw no(
          403,
          'Content stream finished due to exceeded streaming time.',
        );
      }
      final text = activity['text']! as String;
      if (!text.contains(written[id]!.lastOrNull?.trim() ?? '')) {
        throw no(400, 'a final without the text streamed before it');
      }
      finals[id] = text;
      _last[id] = (sequence: last.sequence, at: now);
      return null;
    }
    final sequence = info['streamSequence']! as int;
    _last[id] = (sequence: last.sequence, at: now);
    // ContentStreamSequenceOrderPreConditionFailed, answered 202: dropped.
    if (sequence <= last.sequence) return null;
    _last[id] = (sequence: sequence, at: now);
    _take(id, info, activity);
    return null;
  }

  /// One update to stream [id]: shown, grown, or, once it has text, an
  /// informative update that Teams takes and does not show.
  void _take(String id, Map<String, Object?> info, Map<String, Object?> a) {
    final text = a['text']! as String;
    if (info['streamType'] == 'informative') {
      (written[id]!.isEmpty ? shown[id]! : hidden).add(text);
      return;
    }
    if (!text.startsWith(written[id]!.lastOrNull ?? '')) {
      throw BotConnectorException(
        'post',
        403,
        'Request streamed content should contain the previously streamed '
            'content',
      );
    }
    written[id]!.add(text);
  }

  /// The typing dots posted, with no stream.
  int get dots => posted.where((a) => a['entities'] == null).length;
}

const merge = MergeAsked(
  number: 42,
  base: BranchName('release'),
  landsIn: LandsIn.defaultBranch,
  method: MergeMethod.squash,
);

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
  late FakeTeams teams;
  late JourneyBridge bridge;
  late List<Map<String, Object?>> sent;
  late List<String> ids;
  late List<(String, Map<String, Object?>)> updated;
  late List<String> logged;
  var nextId = 0;

  JourneyBridge bridgeFor(
    ActorId? who, {
    Duration streamEvery = Duration.zero,
  }) => JourneyBridge(
    journeys: host,
    owner: who,
    send: (url, conversation, activity) async {
      sent.add(activity);
      ids.add('act-${nextId++}');
      return ids.last;
    },
    post: (url, conversation, activity) =>
        teams.post(url, conversation, activity),
    update: (url, conversation, id, activity) async =>
        updated.add((id, activity)),
    log: logged.add,
    retryAfter: const Duration(milliseconds: 10),
    typingEvery: Duration.zero,
    streamEvery: streamEvery,
  );

  setUp(() {
    host = FakeJourneys();
    teams = FakeTeams();
    sent = [];
    ids = [];
    updated = [];
    logged = [];
    nextId = 0;
    bridge = bridgeFor(owner);
  });
  tearDown(() => bridge.close());

  JsonObject message(
    String text, {
    String user = nick,
    String activity = 'msg-1',
  }) => JsonObject.of({
    'event': 'teams_message',
    'tenant': tenant,
    'conversation': chat,
    'activity': activity,
    'service_url': '$serviceUrl',
    'from_aad_object_id': user,
    'text': text,
  });

  JsonObject press(
    String verb, {
    String card = 'card',
    String? journey,
    String? repo,
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
        'data': {'journey': ?journey, 'repo': ?repo},
      },
    },
  });

  String textOf(Map<String, Object?> activity) => activity['text']! as String;

  /// The cards of steps sent, as JSON.
  List<String> stepCards() => [
    for (final a in sent)
      if (jsonEncode(a).contains('Working…')) jsonEncode(a),
  ];

  /// What the cards of steps were edited to, as JSON, in order.
  List<String> stepEdits() => [for (final (_, a) in updated) jsonEncode(a)];

  /// The messages sent as text, leaving out cards.
  List<String> texts() => [
    for (final a in sent)
      if (a['text'] case final String t) t,
  ];

  String cardOf(Map<String, Object?> activity) => jsonEncode(activity);

  /// Opens journey `j1` in this chat.
  Future<void> opened() async {
    host.listed.add(journey('j1', events: 7, name: 'teams-bridge'));
    await bridge.onDoorbell(press('open', journey: 'j1'));
    sent.clear();
    ids.clear();
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
      expect(bridge.openIn(chat), JourneyPathId('j1'));
      expect(host.streams.single.after, 6);
      expect(host.streams.single.afterAt, lastActive);
    });

    test('a host it cannot read is said, not silence', () async {
      host.unreadable = const FormatException('no journey_paths');
      await bridge.onDoorbell(message('journeys'));
      expect(texts(), [
        'The agent host could not answer: '
            'FormatException: no journey_paths',
      ]);
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

  group('starting a journey', () {
    const task = 'Tidy the README and fix its broken links please';

    RepoChoice repo(String name) => RepoChoice.fromJson(
      JsonObject.of({
        'path': '/src/$name',
        'name': name,
        'last_used': '2026-11-10T00:00:00Z',
        'self': false,
      }),
    );

    /// The owner asks for a journey with [task] in message `msg-1`, from
    /// eight repos, and is offered the card `act-0`.
    Future<void> offered() async {
      host.repoChoices.addAll([for (var i = 0; i < 8; i++) repo('r$i')]);
      await bridge.onDoorbell(message('new $task'));
    }

    test('"new" offers the repos used most recently', () async {
      await offered();
      final card = cardOf(sent.single);
      expect(card, contains(task));
      for (var i = 0; i < 6; i++) {
        expect(card, contains('"repo":"/src/r$i"'));
      }
      expect(card, isNot(contains('/src/r6')));
      expect(host.starts, isEmpty);
    });

    test('"new" alone says how', () async {
      await bridge.onDoorbell(message('new'));
      expect(textOf(sent.single), contains('new tidy the README'));
      expect(host.repoChoices, isEmpty);
    });

    test(
      'a press starts it there as the newest journey did, and opens it',
      () async {
        host.listed.addAll([
          journey('older', lastActiveAt: DateTime.utc(2026, 11, 1)),
          journey(
            'newest',
            provider: 'chatgpt',
            model: 'gpt-6.1-sol',
            lastActiveAt: DateTime.utc(2026, 11, 9),
          ),
        ]);
        host.starting = journey('j9', events: 1);
        await offered();
        await bridge.onDoorbell(press('start', card: 'act-0', repo: '/src/r2'));
        final run = host.starts.single;
        expect(run.task, task);
        expect(run.root, const RepoPath('/src/r2'));
        expect(run.provider, const Provider('chatgpt'));
        expect(run.model?.value, 'gpt-6.1-sol');
        expect(run.name?.value, 'Tidy the README and fix its');
        expect(updated.map((u) => u.$1).toSet(), {'act-0'});
        expect(cardOf(updated.last.$2), contains('Started in r2.'));
        expect(bridge.openIn(chat), JourneyPathId('j9'));
        expect(host.streams.single.after, 0);
        expect(host.streams.single.afterAt, isNull);
      },
    );

    test(
      'its first turn streams under the message that asked for it',
      () async {
        host.starting = journey('j9', events: 1);
        await offered();
        await bridge.onDoorbell(press('start', card: 'act-0', repo: '/src/r0'));
        await host.feed(1, [
          const UserSaid(task),
          const ReplyText('On it.'),
          const StatusChanged(JourneyState.idle),
        ]);
        expect(teams.shown, {
          'stream-0': ['Working…'],
        });
        expect(teams.written, {
          'stream-0': ['On it.'],
        });
        expect(teams.finals, {'stream-0': 'On it.'});
        expect(teams.posted.map((a) => a['replyToId']).toSet(), {'msg-1'});
      },
    );

    test('a start the host refuses says why on its card', () async {
      await offered();
      host.refuse = 'no credential for anthropic';
      await bridge.onDoorbell(press('start', card: 'act-0', repo: '/src/r0'));
      expect(cardOf(updated.last.$2), contains('no credential for anthropic'));
      expect(bridge.openIn(chat), isNull);
    });

    test('an offer starts once', () async {
      host.starting = journey('j9', events: 1);
      await offered();
      await bridge.onDoorbell(press('start', card: 'act-0', repo: '/src/r0'));
      await bridge.onDoorbell(press('start', card: 'act-0', repo: '/src/r1'));
      expect(host.starts.single.root, const RepoPath('/src/r0'));
      expect(textOf(sent.last), contains('That start has gone'));
    });

    test('a card older than the newest offer starts nothing', () async {
      host.starting = journey('j9', events: 1);
      await offered();
      await bridge.onDoorbell(press('start', card: 'old', repo: '/src/r0'));
      expect(host.starts, isEmpty);
      expect(textOf(sent.last), contains('That start has gone'));
    });
  });

  group('talking into it', () {
    test('a message is said into the journey open', () async {
      await opened();
      await bridge.onDoorbell(message('add a test'));
      expect(host.said.single, (JourneyPathId('j1'), 'add a test'));
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
      expect(host.stopped.single, JourneyPathId('j1'));
    });
  });

  group('what it shows', () {
    test('a turn started in the app has its card of steps, dots while it '
        'writes, and is one message when it ends', () async {
      await opened();
      await host.feed(7, [
        const UserSaid('from the app'),
        const ThinkingText('Hm.'),
        ToolCalled(
          id: 't',
          name: const ToolName('ls'),
          input: JsonObject.empty,
        ),
        const ReplyText('Added '),
        const ReplyText('one.'),
      ]);
      expect(texts(), ['_Said in the app:_ from the app']);
      expect(stepCards().single, contains('› ls'));
      await host.feed(12, [const StatusChanged(JourneyState.idle)]);
      expect(texts(), ['_Said in the app:_ from the app', 'Added one.']);
      expect(stepEdits().last, contains('Ran 1 tool'));
      expect(teams.dots, 3);
      expect(teams.posted.where((a) => a['entities'] != null), isEmpty);
    });

    test(
      'what was said in the app is shown, and its own echo is not',
      () async {
        await opened();
        await bridge.onDoorbell(message('from teams'));
        await host.feed(7, [
          const UserSaid('from teams'),
          const ReplyText('Heard.'),
          const StatusChanged(JourneyState.idle),
          const UserSaid('from the app'),
        ]);
        expect(teams.finals.values, ['Heard.']);
        expect(texts(), ['_Said in the app:_ from the app']);
      },
    );

    test('a failed turn says so, after what it had replied', () async {
      await opened();
      await host.feed(7, [
        const ReplyText('Half'),
        const StatusChanged(JourneyState.failed, detail: 'overloaded'),
      ]);
      expect(texts(), ['Half', 'It failed: overloaded']);
    });
  });

  group('questions', () {
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

  group("the stream under the owner's message", () {
    /// What the host does first when it takes what the owner said: it says
    /// it back. It never says a journey is running, only that it stopped.
    const begun = UserSaid('go');
    const idle = StatusChanged(JourneyState.idle);

    /// The owner says "go" here, into journey `j1`.
    Future<void> said() async {
      await opened();
      await bridge.onDoorbell(message('go'));
    }

    test('shows what the turn is doing, and its reply ends it', () async {
      await said();
      await host.feed(7, [
        begun,
        const ThinkingText('Let me '),
        const ThinkingText('look.'),
        ToolCalled(
          id: 't1',
          name: const ToolName('bash'),
          input: JsonObject.of({'timeout': 5, 'command': 'ls\n  test'}),
        ),
        const ThinkingText('Now write.'),
        const ReplyText('Added '),
        const ReplyText('one.'),
        idle,
      ]);
      // Until its first words, the stream's status says what it is doing,
      // so it needs no card; then the reply grows in it, and ends it.
      expect(sent, isEmpty);
      expect(teams.shown, {
        'stream-0': [
          'Working…',
          'Thinking: Let me',
          'Thinking: Let me look.',
          'Running bash: ls test',
          'Thinking: Now write.',
        ],
      });
      expect(teams.hidden, isEmpty);
      expect(teams.written, {
        'stream-0': ['Added ', 'Added one.'],
      });
      expect(teams.finals, {'stream-0': 'Added one.'});
      expect(teams.posted.map((a) => a['replyToId']).toSet(), {'msg-1'});
      expect(logged, isEmpty);
    });

    test('tools once it has written go on a card, which ends as one line, its '
        'tools a press away', () async {
      await said();
      await host.feed(7, [
        begun,
        const ReplyText('Checking.'),
        ToolCalled(
          id: 't1',
          name: const ToolName('git_log'),
          input: JsonObject.of({'range': '-5'}),
        ),
        const ThinkingText('Fine.'),
        ToolCalled(
          id: 't2',
          name: const ToolName('git_status'),
          input: JsonObject.empty,
        ),
        const ReplyText('Clean.'),
        idle,
      ]);
      expect(stepCards().single, contains('› git_log: -5'));
      // Its dots play while it works, and are gone once it is done.
      expect(stepCards().single, contains('data:image/gif;base64,'));
      final edits = stepEdits();
      expect(edits.last, isNot(contains('data:image/gif')));
      expect(edits[0], contains('_Thinking: Fine._'));
      expect(edits[1], contains('› git_status'));
      expect(edits[1], isNot(contains('Thinking')));
      expect(edits.last, contains('Ran 2 tools'));
      expect(edits.last, contains('Show steps'));
      expect(edits.last, contains('› git_log: -5'));
      expect(edits.last, isNot(contains('Working')));
      expect(updated.map((u) => u.$1).toSet(), {ids.single});
      // The stream showed no tool: it had text by then.
      expect(teams.shown, {
        'stream-0': ['Working…'],
      });
      expect(teams.hidden, isEmpty);
      expect(teams.finals, {'stream-0': 'Checking.\n\nClean.'});
    });

    test(
      'the card shows the newest tools, and says how many came before',
      () async {
        await said();
        await host.feed(7, [
          begun,
          const ReplyText('Many.'),
          for (var i = 0; i < 10; i++)
            ToolCalled(
              id: 't$i',
              name: ToolName('t$i'),
              input: JsonObject.empty,
            ),
        ]);
        final last = stepEdits().last;
        expect(last, contains('…and 2 more'));
        expect(last, isNot(contains('› t1"')));
        expect(last, contains('› t2'));
        expect(last, contains('› t9'));
      },
    );

    test('its card changes no faster than a stream may', () async {
      const every = Duration(milliseconds: 50);
      teams = FakeTeams(every: every);
      bridge = bridgeFor(owner, streamEvery: every);
      await said();
      await host.feed(7, [
        begun,
        const ReplyText('Looking.'),
        for (final t in ['a', 'b', 'c'])
          ToolCalled(id: t, name: ToolName(t), input: JsonObject.empty),
      ]);
      expect(stepCards().single, contains('› a'));
      expect(updated, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(stepEdits().single, contains('› c'));
    });

    test('a long thought shows only its newest words', () async {
      await said();
      await host.feed(7, [begun, ThinkingText('${'a' * 150}${'b' * 150}')]);
      expect(
        teams.shown['stream-0']!.last,
        'Thinking: …${'a' * 49}${'b' * 150}',
      );
    });

    test('it shows the newest text, no faster than Teams takes it', () async {
      const every = Duration(milliseconds: 50);
      teams = FakeTeams(every: every);
      bridge = bridgeFor(owner, streamEvery: every);
      await said();
      await host.feed(7, [
        begun,
        const ThinkingText('a'),
        const ThinkingText('b'),
        const ThinkingText('c'),
      ]);
      expect(teams.shown['stream-0'], ['Working…']);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(teams.shown['stream-0'], ['Working…', 'Thinking: abc']);
      // The reply comes too soon after: its final message waits its turn,
      // and the update it would have been is never sent.
      await host.feed(11, [
        const ReplyText('Thought.'),
        const ReplyText(' Twice.'),
        idle,
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(teams.written, {'stream-0': isEmpty});
      expect(teams.finals, {'stream-0': 'Thought. Twice.'});
      expect(logged, isEmpty);
    });

    test('a question ends the stream before its card; the rest of the turn '
        'has its tools on a card, and dots', () async {
      await said();
      await host.feed(7, [begun, const ThinkingText('Merging.'), merge]);
      expect(teams.finals, {'stream-0': 'It has a question.'});
      expect(cardOf(sent.single), contains('Merge PR #42'));
      await host.feed(10, [
        const MergeAnswered(ask: 9, approved: true),
        const ThinkingText('Merged.'),
        ToolCalled(
          id: 't',
          name: const ToolName('gh_pr_view'),
          input: JsonObject.empty,
        ),
        const ReplyText('Merged it.'),
        idle,
      ]);
      expect(stepCards().single, contains('› gh_pr_view'));
      expect(teams.shown.keys, ['stream-0']);
      expect(teams.dots, 2);
      expect(texts().last, 'Merged it.');
    });

    test('a failed turn ends it with its reply, then says it failed', () async {
      await said();
      await host.feed(7, [
        begun,
        const ReplyText('Half'),
        const StatusChanged(JourneyState.failed, detail: 'overloaded'),
      ]);
      expect(teams.finals, {'stream-0': 'Half'});
      expect(texts(), ['It failed: overloaded']);
    });

    test('a turn that fails before replying ends it with that', () async {
      await said();
      await host.feed(7, [
        begun,
        const StatusChanged(JourneyState.failed, detail: 'overloaded'),
      ]);
      expect(teams.finals, {'stream-0': 'It failed: overloaded'});
      expect(texts(), isEmpty);
    });

    test('a turn with no reply ends it all the same', () async {
      await said();
      await host.feed(7, [begun, idle]);
      expect(teams.finals, {'stream-0': 'Done.'});
    });

    test(
      'a turn with no stream and no reply adds nothing as it ends',
      () async {
        await opened();
        await host.feed(7, [
          const UserSaid('from the app'),
          const ThinkingText('Hm.'),
          const StatusChanged(JourneyState.idle),
        ]);
        expect(texts(), ['_Said in the app:_ from the app']);
      },
    );

    test('a later end of a turn already ended says nothing', () async {
      await said();
      await host.feed(7, [begun, const ReplyText('Hi.'), idle, idle]);
      expect(teams.finals, {'stream-0': 'Hi.'});
      expect(texts(), isEmpty);
    });

    test('a message the host refused starts no stream', () async {
      await opened();
      host.refuse = 'still working';
      await bridge.onDoorbell(message('and another thing'));
      await host.feed(7, [const ThinkingText('still on the last one')]);
      await host.feed(8, [const ReplyText('Still.')]);
      expect(teams.posted.where((a) => a['entities'] != null), isEmpty);
      expect(teams.dots, 2);
    });

    test(
      'a message the host refused is not taken for its echo later',
      () async {
        await opened();
        host.refuse = 'still working';
        await bridge.onDoorbell(message('go'));
        await host.feed(7, [const UserSaid('go'), idle]);
        expect(texts(), ['Not sent: still working', '_Said in the app:_ go']);
      },
    );

    test('an echo that comes before the host answers shows in it', () async {
      await opened();
      host.echoAt = 7;
      await bridge.onDoorbell(message('go'));
      expect(teams.shown, {
        'stream-0': ['Working…'],
      });
      await host.feed(8, [const ReplyText('Hi.'), idle]);
      expect(teams.written, {
        'stream-0': ['Hi.'],
      });
      expect(teams.finals, {'stream-0': 'Hi.'});
      expect(teams.dots, 0);
    });

    test('a second message never takes the place of one started', () async {
      await said();
      await host.feed(7, [begun]);
      await bridge.onDoorbell(message('two', activity: 'msg-2'));
      await host.feed(8, [
        const UserSaid('two'),
        const ReplyText('Both.'),
        idle,
      ]);
      expect(teams.finals, {'stream-0': 'Both.'});
      expect(logged, isEmpty);
    });

    test('a message while the last turn winds down has a stream of its '
        'own', () async {
      await said();
      await host.feed(7, [begun, const ReplyText('Hi.')]);
      // Said before the host has said the last turn is over.
      await bridge.onDoorbell(message('two', activity: 'msg-2'));
      await host.feed(9, [
        idle,
        const UserSaid('two'),
        const ReplyText('Again.'),
        idle,
      ]);
      expect(teams.finals, {'stream-0': 'Hi.', 'stream-1': 'Again.'});
      expect(teams.posted.map((a) => a['replyToId']).toSet(), {
        'msg-1',
        'msg-2',
      });
      expect(teams.dots, 0);
      expect(logged, isEmpty);
    });

    test('a message said before the last was echoed takes nothing from '
        'it', () async {
      await said();
      await bridge.onDoorbell(message('two', activity: 'msg-2'));
      await host.feed(7, [
        begun,
        const ReplyText('Hi.'),
        idle,
        const UserSaid('two'),
        const ReplyText('Again.'),
        idle,
      ]);
      expect(teams.finals, {'stream-0': 'Hi.', 'stream-1': 'Again.'});
      final firsts = teams.posted.where(
        (a) => jsonEncode(a).contains('"streamSequence":1'),
      );
      expect(firsts.map((a) => a['replyToId']), ['msg-1', 'msg-2']);
      expect(teams.dots, 0);
    });

    test('a host that says it is running leaves the stream as it is', () async {
      await said();
      await host.feed(7, [
        begun,
        const ThinkingText('Hm.'),
        const StatusChanged(JourneyState.running),
        ToolCalled(
          id: 't',
          name: const ToolName('ls'),
          input: JsonObject.empty,
        ),
        const StatusChanged(JourneyState.running),
        const ReplyText('Still here.'),
        idle,
      ]);
      expect(sent, isEmpty);
      expect(teams.shown, {
        'stream-0': ['Working…', 'Thinking: Hm.', 'Running ls'],
      });
      expect(teams.written, {
        'stream-0': ['Still here.'],
      });
      expect(teams.finals, {'stream-0': 'Still here.'});
    });

    test('the reply grows through the turn in one stream, and what it wrote '
        'after a tool is a paragraph of its own', () async {
      await said();
      await host.feed(7, [
        begun,
        const ReplyText('Let me check.'),
        ToolCalled(
          id: 't1',
          name: const ToolName('bash'),
          input: JsonObject.of({'command': 'dart test'}),
        ),
        const ThinkingText('Passing.'),
        const ReplyText('All '),
        const ReplyText('good.'),
        idle,
      ]);
      expect(teams.written, {
        'stream-0': [
          'Let me check.',
          'Let me check.\n\nAll ',
          'Let me check.\n\nAll good.',
        ],
      });
      expect(teams.finals, {'stream-0': 'Let me check.\n\nAll good.'});
      expect(stepEdits().first, contains('› bash: dart test'));
      expect(stepEdits().last, contains('Ran 1 tool'));
      expect(texts(), isEmpty);
      expect(teams.posted.map((a) => a['replyToId']).toSet(), {'msg-1'});
      expect(logged, isEmpty);
    });

    test(
      'a reply that starts with blank lines streams from its words',
      () async {
        await said();
        await host.feed(7, [
          begun,
          const ReplyText('\n\n'),
          const ReplyText('Hi.'),
          idle,
        ]);
        expect(teams.written, {
          'stream-0': ['Hi.'],
        });
        expect(teams.finals, {'stream-0': 'Hi.'});
      },
    );

    test(
      'where Teams refuses one, the turn has dots and a plain reply',
      () async {
        teams.refuse = 'Content stream is not allowed';
        await said();
        await host.feed(7, [
          begun,
          const ThinkingText('Hm.'),
          ToolCalled(
            id: 't',
            name: const ToolName('ls'),
            input: JsonObject.empty,
          ),
          const ReplyText('Hi.'),
          idle,
        ]);
        expect(texts(), ['Hi.']);
        expect(stepCards().single, contains('› ls'));
        expect(teams.dots, 2);
        expect(logged.single, contains('not allowed'));
      },
    );

    test('a final message Teams refuses is sent plain instead', () async {
      teams.refuseFinal = true;
      await said();
      await host.feed(7, [begun, const ReplyText('At last.'), idle]);
      expect(texts(), ['At last.']);
      expect(logged.single, contains('final'));
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
      expect(texts(), ['new']);
      // And again, from the top, once it has moved on.
      await host.feed(0, [
        const ReplyText('older still'),
        const StatusChanged(JourneyState.idle),
      ]);
      expect(texts(), ['new']);
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
    expect(texts(), ['one moment']);
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
      expect(texts(), ['before', 'after']);
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
