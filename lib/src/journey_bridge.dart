import 'dart:async';
import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:intersyntactic_protocol/intersyntactic_protocol.dart'
    show
        JourneyName,
        JourneyPathId,
        JourneyState,
        LoggedEvent,
        MemoryAnswered,
        MemoryAsked,
        MergeAnswered,
        MergeAsked,
        Provider,
        ReplyText,
        RepoPath,
        RunSummary,
        StartRun,
        StatusChanged,
        ThinkingText,
        ToolAnswered,
        ToolAsked,
        ToolCalled,
        ToolOffered,
        UserSaid;
import 'package:is_shapes/is_shapes.dart' show ActorId;

import 'agent_host_client.dart';
import 'teams_receiver.dart' show teamsActor;

/// Sends [activity] to [conversation] and returns its id.
typedef TeamsSend = Future<String> Function(
  Uri serviceUrl,
  String conversation,
  Map<String, Object?> activity,
);

/// Posts [activity] to [conversation]; its id, if Teams gave it one.
typedef TeamsPost = Future<String?> Function(
  Uri serviceUrl,
  String conversation,
  Map<String, Object?> activity,
);

/// Replaces the bot's own message [activityId] in [conversation].
typedef TeamsUpdate = Future<void> Function(
  Uri serviceUrl,
  String conversation,
  String activityId,
  Map<String, Object?> activity,
);

/// The owner's own journeys, from Teams: a chat has one journey open, shows
/// its replies and its questions, and sends what the owner says into it.
///
/// In a chat, "journeys" offers the active ones to open, and "stop" stops the
/// one open. Anything else is said into it, as the person's own message.
/// A question the journey asks (a merge, a tool, a memory) arrives as a card,
/// and its Yes or No is the person's 1 or 2, which the host reads itself.
///
/// While a turn the owner started here works, a stream under their message
/// says what it is doing (thinking, running a tool) until it writes, and
/// then its reply grows in place as it is written. Teams shows no status in
/// a stream once it has text, so a tool the turn runs after that goes on a
/// card of steps instead, edited in place, which ends as one line, its tools
/// a press away; what it writes after a tool is a paragraph of its own.
/// Teams streams only an answer to a message, so a turn started in the app
/// has the card for its tools, and typing dots.
///
/// Only [owner]'s messages and presses reach a journey. A journey's agent has
/// the whole of the owner's machine, so the tenant allowlist the gate keeps is
/// not enough: anyone else in the tenant is answered, and nothing they send
/// goes further.
final class JourneyBridge {
  JourneyBridge({
    required this.journeys,
    required this.owner,
    required this.send,
    required this.post,
    required this.update,
    required this.log,
    this.retryAfter = const Duration(seconds: 2),
    this.typingEvery = const Duration(seconds: 3),
    this.streamEvery = const Duration(seconds: 1),
  });

  final Journeys journeys;

  /// Whose messages reach a journey; null until the owner is configured,
  /// when nobody's do.
  final ActorId? owner;

  final TeamsSend send;

  /// For what Teams may answer with no id: typing, and a stream's updates.
  final TeamsPost post;

  final TeamsUpdate update;

  /// Where the bridge says what it refused, and why.
  final void Function(String) log;

  /// How long to wait before reading a journey's events again after they
  /// stopped coming.
  final Duration retryAfter;

  /// How often to say the journey is typing while it works.
  final Duration typingEvery;

  /// How often a stream may change: Teams takes one request a second on
  /// each.
  final Duration streamEvery;

  final _chats = <String, _Chat>{};

  /// A journey offered to start, by conversation: its task, the owner's
  /// message that asked for it, and the card of repos to start it in.
  final _starts = <String, ({String task, String asked, String card})>{};

  /// The journey open in [conversation], or null.
  JourneyPathId? openIn(String conversation) => _chats[conversation]?.journey;

  /// Answers one doorbell from the relay.
  Future<void> onDoorbell(JsonObject bell) async {
    final event = bell.string('event');
    if (event != 'teams_message' && event != 'teams_card_action') return;
    final at = (
      serviceUrl: Uri.parse(bell.string('service_url')),
      conversation: bell.string('conversation'),
    );
    final by = teamsActor(bell);
    if (owner == null || by != owner) {
      log('teams journey: a $event from $by, who is not the owner');
      if (event == 'teams_message') {
        await _say(
          at,
          owner == null
              ? 'No owner yet: start the bridge with TEAMS_OWNER=$by to '
                    'answer you.'
              : 'This bot answers only its owner.',
        );
      }
      return;
    }
    if (event == 'teams_message') {
      await _message(
        at,
        _plain(bell.stringOrNull('text') ?? ''),
        activity: bell.string('activity'),
      );
    } else {
      final action = bell.objectOrNull('value')?.objectOrNull('action');
      await _press(
        at,
        card: bell.stringOrNull('reply_to'),
        verb: action?.stringOrNull('verb'),
        journey: action?.objectOrNull('data')?.stringOrNull('journey'),
        repo: action?.objectOrNull('data')?.stringOrNull('repo'),
      );
    }
  }

  Future<void> _message(_At at, String text, {required String activity}) async {
    final chat = _chats[at.conversation];
    switch (text.toLowerCase()) {
      case 'journeys':
        await _offer(at);
      case 'new':
        await _say(at, 'Say "new" and what it is for: new tidy the README.');
      case final t when t.startsWith('new '):
        await _offerStart(at, text.substring(4).trim(), asked: activity);
      case 'stop' when chat != null:
        final why = await journeys.stop(chat.journey);
        await _say(at, why == null ? 'Stopped.' : 'Not stopped: $why');
      case _ when chat == null:
        await _say(at, 'Say "journeys" to open one.');
      case _:
        // Before it is said: the host can send its echo, which takes up
        // this stream, before it answers.
        final waiting = (text: text, stream: _Stream(activity));
        chat.said.add(waiting);
        final why = await journeys.say(chat.journey, text);
        if (why != null) {
          chat.said.remove(waiting);
          await _say(at, 'Not sent: $why');
        }
    }
  }

  Future<void> _press(
    _At at, {
    required String? card,
    required String? verb,
    required String? journey,
    String? repo,
  }) async {
    final chat = _chats[at.conversation];
    switch (verb) {
      case 'start' when repo != null:
        final offer = _starts[at.conversation];
        // Only on the newest offer: each start is pressed once.
        if (offer == null || offer.card != card) {
          await _say(at, 'That start has gone: say "new" and the task again.');
          return;
        }
        _starts.remove(at.conversation);
        await _start(at, offer, RepoPath(repo));
      case 'open' when journey != null:
        final active = await _active();
        final j = active.where((j) => j.id.value == journey).firstOrNull;
        if (j == null) {
          await _say(at, 'That journey has ended.');
        } else {
          await _open(at, j);
        }
      // Only on the card of a question still open: a bare 1 or 2 with no
      // question waiting is a message, and would start a turn.
      case 'yes' || 'no'
          when chat != null && chat.asks.values.any((a) => a.card == card):
        final why = await journeys.say(chat.journey, verb == 'yes' ? '1' : '2');
        if (why != null) await _say(at, 'Not answered: $why');
      default:
        log('teams journey: a press with verb $verb on card $card');
    }
  }

  /// The journeys not yet ended, the most recently active first: "a journey
  /// is active until its state is `ended`" (RULINGS).
  Future<List<RunSummary>> _active() async =>
      (await journeys.list())
          .where((j) => j.state != JourneyState.ended)
          .toList()
        ..sort((a, b) => b.lastActiveAt.compareTo(a.lastActiveAt));

  /// A card of the active journeys, each with a button to open it.
  Future<void> _offer(_At at) async {
    final active = await _active();
    if (active.isEmpty) return _say(at, 'No journey is active.');
    await send(at.serviceUrl, at.conversation, {
      'type': 'message',
      'attachments': [
        _cardOf([
          {
            'type': 'TextBlock',
            'text': 'Active journeys',
            'weight': 'Bolder',
            'wrap': true,
          },
          for (final j in active.take(10)) ...[
            {
              'type': 'TextBlock',
              'text':
                  '${_title(j)} · ${j.state.name}'
                  '${j.awaiting ? ' · waiting for you' : ''}',
              'wrap': true,
              'separator': true,
            },
            {
              'type': 'ActionSet',
              'actions': [
                {
                  'type': 'Action.Execute',
                  'title': 'Open',
                  'verb': 'open',
                  'data': {'journey': j.id.value},
                },
              ],
            },
          ],
        ]),
      ],
    });
  }

  /// A card offering to start a journey for [task] in one of the repos used
  /// most recently, as a reply to the owner's message [asked].
  Future<void> _offerStart(_At at, String task, {required String asked}) async {
    final repos = (await journeys.repos()).take(6).toList();
    if (repos.isEmpty) return _say(at, 'There is no repo to start one in.');
    final card = await send(at.serviceUrl, at.conversation, {
      'type': 'message',
      'attachments': [
        _startCard(task, 'Start it in:', [
          for (final r in repos)
            {
              'type': 'Action.Execute',
              'title': r.name,
              'verb': 'start',
              'data': {'repo': r.path.value},
            },
        ]),
      ],
    });
    _starts[at.conversation] = (task: task, asked: asked, card: card);
  }

  /// Starts [offer]'s journey in [repo], with the provider and model of the
  /// journey active most recently, and opens it here. Its first turn streams
  /// under the message that asked for it.
  Future<void> _start(
    _At at,
    ({String task, String asked, String card}) offer,
    RepoPath repo,
  ) async {
    final where = repo.value.split('/').last;
    Future<void> say(String line) =>
        update(at.serviceUrl, at.conversation, offer.card, {
          'type': 'message',
          'attachments': [_startCard(offer.task, line)],
        });
    await say('Starting in $where…');
    final last = (await journeys.list()).fold<RunSummary?>(
      null,
      (a, b) => a == null || b.lastActiveAt.isAfter(a.lastActiveAt) ? b : a,
    );
    final (:started, :why) = await journeys.start(
      StartRun(
        task: offer.task,
        root: repo,
        provider: last?.provider ?? Provider.anthropic,
        model: last?.model,
        effort: last?.effort,
        name: _nameFor(offer.task),
      ),
    );
    if (started == null) return say('Not started in $where: $why');
    await say('Started in $where.');
    await _chats.remove(at.conversation)?.close();
    // After its first event, which says it started: the task comes back
    // next, as what the owner said.
    final chat = _Chat(at, started.id, after: 0, afterAt: null)
      ..said.add((text: offer.task, stream: _Stream(offer.asked)));
    _chats[at.conversation] = chat;
    _listen(chat);
  }

  /// A journey's name from its task: its first words.
  static JourneyName? _nameFor(String task) {
    final words = _oneLine(task).split(' ').take(6).join(' ');
    return JourneyName.parse(_clip(words, 50));
  }

  static Map<String, Object?> _startCard(
    String task,
    String line, [
    List<Map<String, Object?>> actions = const [],
  ]) => _cardOf([
    {
      'type': 'TextBlock',
      'text': 'New journey',
      'weight': 'Bolder',
      'wrap': true,
    },
    {'type': 'TextBlock', 'text': _clip(task, 400), 'wrap': true},
    {'type': 'TextBlock', 'text': line, 'wrap': true, 'isSubtle': true},
  ], actions);

  Future<void> _open(_At at, RunSummary j) async {
    await _chats.remove(at.conversation)?.close();
    // A journey's summary says when its newest event happened.
    final chat = _Chat(
      at,
      j.id,
      after: j.events - 1,
      afterAt: j.events == 0 ? null : j.lastActiveAt,
    );
    _chats[at.conversation] = chat;
    _listen(chat);
    await _say(
      at,
      'Opened ${_title(j)}: ${j.state.name}.'
      '${j.awaiting ? ' It is waiting on a question asked before now: '
                'answer it in the app.' : ''}',
    );
  }

  /// Reads [chat]'s journey's events from where it got to, and again after
  /// [retryAfter] whenever they stop, until the chat opens another.
  void _listen(_Chat chat) {
    chat.events = journeys
        .events(chat.journey, after: chat.after, afterAt: chat.afterAt)
        .listen(
          (e) {
            // A host that could not resume sends its whole log again.
            if (!chat.isNew(e)) return;
            chat.after = e.seq;
            chat.afterAt = e.at;
            _later(chat, () => _on(chat, e));
          },
          onError: (Object err) => log('teams journey: events: $err'),
          onDone: () {
            if (chat.closed) return;
            chat.retry = Timer(retryAfter, () {
              if (!chat.closed) _listen(chat);
            });
          },
          cancelOnError: true,
        );
  }

  /// Runs [step] once everything queued in [chat] before it has run.
  void _later(_Chat chat, Future<void> Function() step) {
    chat.queue = chat.queue
        .then((_) => step())
        .catchError((Object err) => log('teams journey: $err'));
  }

  /// What one event of the journey becomes in the chat.
  Future<void> _on(_Chat chat, LoggedEvent e) async {
    switch (e.event) {
      case UserSaid(:final text):
        // What the owner said here comes back as the journey's own record,
        // which is also the sign its turn has begun: the host says nothing
        // when a journey starts running, only when it stops.
        if (chat.echoed(text) case final stream?) {
          // Never in place of a stream still open: Teams keeps one open in
          // a conversation, and it would be left without an end.
          chat.stream ??= stream;
          await _show(chat, 'Working…');
          break;
        }
        await _flush(chat, after: ['_Said in the app:_ $text']);
      case ReplyText(:final text):
        // What it writes after a tool is a paragraph of its own.
        if (chat.stepped) chat.reply.write('\n\n');
        chat.stepped = false;
        chat.label = null;
        chat.reply.write(text);
        await _write(chat);
      case ThinkingText(:final text):
        final line = chat.streamed('Thinking', text);
        if (chat.shimmers) {
          await _show(chat, line);
        } else if (chat.steps case final steps?) {
          steps.live = line;
          await _stepsShowSoon(chat, steps);
        } else {
          await _typing(chat);
        }
      case ToolCalled(:final name, :final input):
        // What streams after a tool call is new: a thought begins again.
        chat.label = null;
        chat.stepped = true;
        if (chat.shimmers) {
          await _show(chat, _running(name.value, input));
        } else {
          // Where the stream cannot show it, the card of steps does.
          final steps = chat.steps ??= _Steps();
          steps.tools.add(_tool(name.value, input));
          steps.live = null;
          await _stepsShowSoon(chat, steps);
        }
      case StatusChanged(:final state, :final detail):
        if (state.busy) {
          await _show(chat);
        } else {
          await _flush(
            chat,
            after: [
              if (state == JourneyState.failed)
                'It failed${detail == null ? '.' : ': $detail'}',
            ],
          );
        }
      case MergeAsked(:final number, :final base):
        await _ask(
          chat,
          e.seq,
          (answer) => _question(
            'Merge PR #$number into ${base.value}?',
            answer: answer,
          ),
        );
      case ToolAsked(:final tool, :final input):
        await _ask(
          chat,
          e.seq,
          (answer) => _question(
            'Run ${tool.value}?',
            input: _clip(jsonEncode(input)),
            answer: answer,
          ),
        );
      case MemoryAsked(:final name, :final type, :final description):
        await _ask(
          chat,
          e.seq,
          (answer) => _question(
            'Keep the $type memory "$name"?',
            detail: description,
            answer: answer,
          ),
        );
      case MergeAnswered(:final ask, :final approved) ||
          ToolAnswered(:final ask, :final approved) ||
          MemoryAnswered(:final ask, :final approved):
        await _answered(chat, ask, approved);
      case ToolOffered():
        await _flush(
          chat,
          after: ['It offers this journey new tools: answer in the app.'],
        );
      default:
        break;
    }
  }

  /// A question as a card, drawn by [draw]: with Yes and No until it is
  /// answered. Its stream ends first, so the card comes after what led to
  /// it, and the rest of the turn has dots.
  Future<void> _ask(_Chat chat, int seq, _Draw draw) async {
    await _flush(chat, orElse: 'It has a question.');
    final id = await send(chat.at.serviceUrl, chat.at.conversation, {
      'type': 'message',
      'attachments': [draw(null)],
    });
    chat.asks[seq] = (card: id, draw: draw);
  }

  /// The question's card, edited to say how it was answered, wherever it was.
  Future<void> _answered(_Chat chat, int seq, bool approved) async {
    final asked = chat.asks.remove(seq);
    if (asked == null) return;
    await update(chat.at.serviceUrl, chat.at.conversation, asked.card, {
      'type': 'message',
      'attachments': [asked.draw(approved)],
    });
  }

  /// The reply so far and then [after], each as a message, and the reply
  /// cleared. While the turn has a stream the first of them is its final
  /// message, or [orElse] if there are none: only a message ends a stream.
  Future<void> _flush(
    _Chat chat, {
    List<String> after = const [],
    String orElse = 'Done.',
  }) async {
    final texts = [...splitForTeams(chat.reply.toString().trim()), ...after];
    chat.reply.clear();
    chat.label = null;
    final stream = chat.stream;
    chat.stream = null;
    // A turn with a stream ends it, even with nothing to say.
    if (texts.isEmpty && stream != null) texts.add(orElse);
    if (chat.steps case final steps?) {
      chat.steps = null;
      await _stepsDone(chat, steps);
    }
    final ended =
        stream != null &&
        texts.isNotEmpty &&
        await _end(chat, stream, texts.first);
    for (final text in ended ? texts.skip(1) : texts) {
      await _say(chat.at, text);
    }
  }

  /// Streams the reply so far into the turn's message, where it grows as it
  /// is written. With no stream, or one Teams refused, the turn has dots.
  Future<void> _write(_Chat chat) async {
    final stream = chat.stream;
    if (stream == null || stream.refused) return _typing(chat);
    // Each text holds all of the one before it, as Teams requires.
    final text = chat.reply.toString().trimLeft();
    if (text.isEmpty) return;
    stream.writing = true;
    return _sendOn(chat, stream, text);
  }

  /// Opens [steps]' card, or shows it as it is now: no more often than a
  /// stream may change.
  Future<void> _stepsShowSoon(_Chat chat, _Steps steps) async {
    if (steps.card == null) {
      try {
        steps.card = await send(chat.at.serviceUrl, chat.at.conversation, {
          'type': 'message',
          'attachments': [_stepsCard(steps)],
        });
      } on Exception catch (e) {
        log('teams journey: steps: $e');
      }
      steps.sentAt = DateTime.now();
      return;
    }
    if (steps.timer != null) return;
    final wait = steps.sentAt.add(streamEvery).difference(DateTime.now());
    if (wait <= Duration.zero) return _stepsShow(chat, steps);
    steps.timer = Timer(wait, () {
      steps.timer = null;
      _later(chat, () => _stepsShow(chat, steps));
    });
  }

  /// [steps] as they are now, on its card, while they are still the turn's.
  Future<void> _stepsShow(_Chat chat, _Steps steps) async {
    final card = steps.card;
    if (chat.steps != steps || card == null) return;
    steps.sentAt = DateTime.now();
    try {
      await update(chat.at.serviceUrl, chat.at.conversation, card, {
        'type': 'message',
        'attachments': [_stepsCard(steps)],
      });
    } on Exception catch (e) {
      log('teams journey: steps: $e');
    }
  }

  /// Ends [steps]' card as one line, its tools a press away.
  Future<void> _stepsDone(_Chat chat, _Steps steps) async {
    steps.timer?.cancel();
    final card = steps.card;
    if (card == null) return;
    final wait = steps.sentAt.add(streamEvery).difference(DateTime.now());
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    try {
      await update(chat.at.serviceUrl, chat.at.conversation, card, {
        'type': 'message',
        'attachments': [_stepsCard(steps, done: true)],
      });
    } on Exception catch (e) {
      log('teams journey: steps: $e');
    }
  }

  /// The card of a turn's steps: while it works, the newest of its tools
  /// and what it is thinking; once done, how many tools it ran, shown on a
  /// press.
  static Map<String, Object?> _stepsCard(_Steps s, {bool done = false}) {
    Map<String, Object?> line(String text) => {
      'type': 'TextBlock',
      'text': text,
      'size': 'Small',
      'isSubtle': true,
      'wrap': true,
      'spacing': 'None',
    };
    final n = s.tools.length;
    if (done) {
      return _cardOf(
        [
          line('Ran $n tool${n == 1 ? '' : 's'}'),
          {
            'type': 'Container',
            'id': 'steps',
            'isVisible': false,
            'items': [for (final t in s.tools) line('› $t')],
          },
        ],
        [
          {
            'type': 'Action.ToggleVisibility',
            'title': 'Show steps',
            'targetElements': ['steps'],
          },
        ],
      );
    }
    const most = 8;
    return _cardOf([
      {
        'type': 'ColumnSet',
        'columns': [
          {
            'type': 'Column',
            'width': 'auto',
            'verticalContentAlignment': 'Center',
            'items': [
              {
                'type': 'Image',
                'url': _dots,
                'width': '24px',
                'height': '8px',
                'altText': 'working',
              },
            ],
          },
          {
            'type': 'Column',
            'width': 'stretch',
            'items': [line('Working…')],
          },
        ],
      },
      if (n > most) line('› …and ${n - most} more'),
      for (final t in s.tools.skip(n > most ? n - most : 0)) line('› $t'),
      if (s.live case final live?) line('_${live}_'),
    ]);
  }

  /// Shows [text], what the turn is doing, in its stream's status, which
  /// Teams draws with a shimmer; with no [text], what it showed last, or
  /// "Working…". Only until the reply's first words: Teams then shows no
  /// status. With no stream, or one Teams refused, the turn has dots.
  Future<void> _show(_Chat chat, [String? text]) async {
    final stream = chat.stream;
    if (stream == null || stream.refused) return _typing(chat);
    if (stream.writing) return;
    return _sendOn(
      chat,
      stream,
      text ?? (stream.next.isEmpty ? 'Working…' : stream.next),
    );
  }

  /// Sends [text] on [stream] now if Teams would take it now, or else once
  /// it would, by when a newer text may have taken its place.
  Future<void> _sendOn(_Chat chat, _Stream stream, String text) async {
    stream.next = text;
    if (stream.timer != null) return;
    final wait = stream.sentAt.add(streamEvery).difference(DateTime.now());
    if (wait <= Duration.zero) return _update(chat, stream);
    stream.timer = Timer(wait, () {
      stream.timer = null;
      _later(chat, () => _update(chat, stream));
    });
  }

  /// Sends [stream]'s next text, if it is still the turn's and the text is
  /// new. The first is answered with the stream's id.
  Future<void> _update(_Chat chat, _Stream stream) async {
    final text = stream.next;
    if (chat.stream != stream || stream.refused || text == stream.shown) {
      return;
    }
    stream.sentAt = DateTime.now();
    try {
      final id = await post(chat.at.serviceUrl, chat.at.conversation, {
        'type': 'typing',
        'replyToId': stream.replyTo,
        'text': text,
        'entities': [
          {
            'type': 'streaminfo',
            'streamId': ?stream.id,
            'streamType': stream.writing ? 'streaming' : 'informative',
            'streamSequence': stream.sequence + 1,
          },
        ],
      });
      stream.sequence++;
      stream.shown = text;
      stream.id ??= id;
      if (stream.id == null) {
        stream.refused = true;
        log('teams journey: stream: Teams gave it no id');
      }
    } on Exception catch (e) {
      stream.refused = true;
      log('teams journey: stream: $e');
    }
  }

  /// Ends [stream] with [text] as its final message; whether Teams took it.
  /// A stream that never started has nothing to end. An update still
  /// waiting finds the stream no longer the turn's, and is not sent.
  Future<bool> _end(_Chat chat, _Stream stream, String text) async {
    final id = stream.id;
    if (id == null) return false;
    // The final message is a request on the stream, and waits its turn.
    final wait = stream.sentAt.add(streamEvery).difference(DateTime.now());
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    try {
      await post(chat.at.serviceUrl, chat.at.conversation, {
        'type': 'message',
        'replyToId': stream.replyTo,
        'textFormat': 'markdown',
        'text': text,
        'entities': [
          {'type': 'streaminfo', 'streamId': id, 'streamType': 'final'},
        ],
      });
      return true;
    } on Exception catch (e) {
      log('teams journey: stream: final: $e');
      return false;
    }
  }

  Future<void> _typing(_Chat chat) async {
    final now = DateTime.now();
    if (now.difference(chat.typedAt) < typingEvery) return;
    chat.typedAt = now;
    try {
      await post(chat.at.serviceUrl, chat.at.conversation, {'type': 'typing'});
    } on Exception catch (e) {
      // A dot that went missing; the reply itself is what matters.
      log('teams journey: typing: $e');
    }
  }

  Future<void> _say(_At at, String text) async {
    await send(at.serviceUrl, at.conversation, {
      'type': 'message',
      'textFormat': 'markdown',
      'text': text,
    });
  }

  /// Closes every journey open in a chat.
  Future<void> close() async {
    for (final chat in _chats.values) {
      await chat.close();
    }
    _chats.clear();
  }

  static String _title(RunSummary j) {
    final name = j.name?.value;
    if (name != null) return name;
    final task = j.task.split('\n').first.trim();
    return task.length <= 60 ? task : '${task.substring(0, 59)}…';
  }

  static String _clip(String s, [int max = 1500]) =>
      s.length <= max ? s : '${s.substring(0, max - 1)}…';

  /// A tool call, for its stream: the tool, and the first of its arguments
  /// that is text, on one line and cut short.
  static String _running(String tool, JsonObject input) =>
      'Running ${_tool(tool, input)}';

  /// A tool call, for the card of steps.
  static String _tool(String tool, JsonObject input) {
    final hint = input.keys.map(input.raw).whereType<String>().firstOrNull;
    if (hint == null) return tool;
    return '$tool: ${_clip(_oneLine(hint), 120)}';
  }

  static String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Text with Teams' `<at>…</at>` mention markup and quote tags taken out.
  static String _plain(String text) => text
      .replaceAll(RegExp(r'<at>[^<]*</at>'), '')
      .replaceAll(RegExp(r'<quoted[^>]*/>'), '')
      .trim();
}

/// [text] in parts of at most [max] characters, each ending at a paragraph
/// where one falls in its second half: a Teams message holds about 28 KB.
List<String> splitForTeams(String text, {int max = 20000}) {
  final parts = <String>[];
  var rest = text;
  while (rest.length > max) {
    final cut = rest.lastIndexOf('\n\n', max);
    final at = cut > max ~/ 2 ? cut : max;
    parts.add(rest.substring(0, at).trimRight());
    rest = rest.substring(at).trimLeft();
  }
  if (rest.isNotEmpty) parts.add(rest);
  return parts;
}

/// Three dots lit in turn, Teams purple on clear, 48 by 16: the card of
/// steps' own shimmer while the turn works. A GIF, so Teams plays it.
const _dots =
    'data:image/gif;base64,'
    'R0lGODlhMAAQAPECAHuD67m+8wAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQJHgACACwA'
    'AAAAMAAQAAACRZSPqcvtD6OcNIKLQd0pe855IhOU5WOei/gpqdm8asdiixzE8lpf904C0nq/'
    'l86o6PlcQiZyWAvCHM9kFBQaYbfcrpdSAAAh+QQJHgACACwFAAMAJwALAAACNZSPKcANCqNc'
    'zk0Vco61R72BGtRVkIiOSmlhKUqyzPmKsUzXaiLPrm27sT6gC29oTB5NSkEBACH5BAUeAAIA'
    'LAUAAwApAAsAAAI3lI+pi+APmJwKWhNypnovC3aaJHoJaJUBWX7oo7Ki+wIxc5+13eK9XhPM'
    'JsPKjoJkBJNMIMRQAAA7';

typedef _At = ({Uri serviceUrl, String conversation});

/// Draws a question's card: open while the answer is null, then answered.
typedef _Draw = Map<String, Object?> Function(bool? answer);

/// A chat with one journey open.
final class _Chat {
  _Chat(this.at, this.journey, {required this.after, required this.afterAt});

  final _At at;
  final JourneyPathId journey;

  /// The newest event seen: its seq, and when it happened.
  int after;
  DateTime? afterAt;

  /// Whether [e] came after the newest event seen: by time first, since a
  /// restarted host can give an old event a new seq, then by seq.
  bool isNew(LoggedEvent e) {
    final seen = afterAt;
    if (seen == null) return true;
    return e.at.isAfter(seen) || (e.at.isAtSameMomentAs(seen) && e.seq > after);
  }

  /// What the owner said from this chat, until the journey records it, each
  /// with the stream that will answer it. Its turn takes the stream up when
  /// the echo comes, never sooner: a turn still ending keeps its own.
  final said = <({String text, _Stream stream})>[];

  /// The stream waiting for [text]'s echo, no longer waiting.
  _Stream? echoed(String text) {
    final i = said.indexWhere((s) => s.text == text);
    return i < 0 ? null : said.removeAt(i).stream;
  }

  /// The reply so far in this turn: the model's text, as it streams.
  final reply = StringBuffer();

  /// Whether it called a tool since it last wrote: its next text begins a
  /// paragraph. Before a reply's first words, or left over from a turn that
  /// ended on a tool, it only puts blank lines before them, trimmed off.
  bool stepped = false;

  /// The cards asking a question, by the seq of the event that asked it.
  final asks = <int, ({String card, _Draw draw})>{};

  /// The stream under the owner's message, from when it starts a turn until
  /// the turn ends or asks.
  _Stream? stream;

  /// Whether the stream can show what the turn is doing: until it has text.
  bool get shimmers {
    final s = stream;
    return s != null && !s.refused && !s.writing;
  }

  /// The card of the tools the stream could not show, from the first of
  /// them until the turn ends or asks.
  _Steps? steps;

  /// What the turn is streaming now, and the newest of what has come under
  /// that label.
  String? label;
  String tail = '';

  /// [label] and the newest of what has streamed under it, [more] last.
  String streamed(String label, String more) {
    final all = label == this.label ? '$tail$more' : more;
    this.label = label;
    tail = all.length <= 200 ? all : '…${all.substring(all.length - 199)}';
    return '$label: ${JourneyBridge._oneLine(tail)}';
  }

  DateTime typedAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> queue = Future.value();
  StreamSubscription<LoggedEvent>? events;
  Timer? retry;
  bool closed = false;

  Future<void> close() async {
    closed = true;
    retry?.cancel();
    stream?.timer?.cancel();
    await events?.cancel();
  }
}

/// A turn's card of steps: the tools it ran where its stream could not show
/// them, and the newest words of what it is thinking.
final class _Steps {
  /// The card's id, once Teams has it.
  String? card;
  final tools = <String>[];
  String? live;
  DateTime sentAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Waiting to show the newest, when the card changed less than a stream's
  /// interval ago.
  Timer? timer;
}

/// A Teams stream under the owner's message: what the turn is doing until
/// it writes, then the reply, growing as it is written, until a final
/// message ends it.
final class _Stream {
  _Stream(this.replyTo);

  /// The owner's message it answers.
  final String replyTo;

  /// Teams' id for it, given for its first update.
  String? id;

  /// How many updates Teams has taken: each is numbered on from the last.
  int sequence = 0;

  /// The text Teams shows, and the text to show next.
  String? shown;
  String next = '';

  DateTime sentAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Waiting to send [next], when Teams would not yet take it.
  Timer? timer;

  /// It carries the reply as it is written: Teams then shows no status.
  bool writing = false;

  /// Teams refused an update: the rest of the turn has dots.
  bool refused = false;
}

Map<String, Object?> _cardOf(
  List<Map<String, Object?>> body, [
  List<Map<String, Object?>> actions = const [],
]) => {
  'contentType': 'application/vnd.microsoft.card.adaptive',
  'content': {
    r'$schema': 'http://adaptivecards.io/schemas/adaptive-card.json',
    'type': 'AdaptiveCard',
    'version': '1.5',
    'body': body,
    if (actions.isNotEmpty) 'actions': actions,
  },
};

/// A question's card: Yes and No while [answer] is null, then how it was
/// answered. [detail] is prose; [input], a tool's arguments, is shown as
/// code.
Map<String, Object?> _question(
  String question, {
  String? detail,
  String? input,
  required bool? answer,
}) => _cardOf(
  [
    {'type': 'TextBlock', 'text': question, 'weight': 'Bolder', 'wrap': true},
    if (detail != null) {'type': 'TextBlock', 'text': detail, 'wrap': true},
    if (input != null)
      {
        'type': 'TextBlock',
        'text': input,
        'wrap': true,
        'fontType': 'Monospace',
      },
    if (answer != null)
      {
        'type': 'TextBlock',
        'text': answer ? 'Yes.' : 'No.',
        'wrap': true,
        'isSubtle': true,
      },
  ],
  [
    if (answer == null) ...[
      {'type': 'Action.Execute', 'title': 'Yes', 'verb': 'yes'},
      {'type': 'Action.Execute', 'title': 'No', 'verb': 'no'},
    ],
  ],
);
