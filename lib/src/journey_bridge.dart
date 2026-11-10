import 'dart:async';
import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:intersyntactic_protocol/intersyntactic_protocol.dart'
    show
        JourneyState,
        LoggedEvent,
        MemoryAnswered,
        MemoryAsked,
        MergeAnswered,
        MergeAsked,
        ReplyText,
        RunId,
        RunSummary,
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
/// Only [owner]'s messages and presses reach a journey. A journey's agent has
/// the whole of the owner's machine, so the tenant allowlist the gate keeps is
/// not enough: anyone else in the tenant is answered, and nothing they send
/// goes further.
final class JourneyBridge {
  JourneyBridge({
    required this.journeys,
    required this.owner,
    required this.send,
    required this.update,
    required this.log,
    this.retryAfter = const Duration(seconds: 2),
    this.typingEvery = const Duration(seconds: 3),
  });

  final Journeys journeys;

  /// Whose messages reach a journey; null until the owner is configured,
  /// when nobody's do.
  final ActorId? owner;

  final TeamsSend send;
  final TeamsUpdate update;

  /// Where the bridge says what it refused, and why.
  final void Function(String) log;

  /// How long to wait before reading a journey's events again after they
  /// stopped coming.
  final Duration retryAfter;

  /// How often to say the journey is typing while it works.
  final Duration typingEvery;

  final _chats = <String, _Chat>{};

  /// The journey open in [conversation], or null.
  RunId? openIn(String conversation) => _chats[conversation]?.journey;

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
      await _message(at, _plain(bell.stringOrNull('text') ?? ''));
    } else {
      final action = bell.objectOrNull('value')?.objectOrNull('action');
      await _press(
        at,
        card: bell.stringOrNull('reply_to'),
        verb: action?.stringOrNull('verb'),
        journey: action?.objectOrNull('data')?.stringOrNull('journey'),
      );
    }
  }

  Future<void> _message(_At at, String text) async {
    final chat = _chats[at.conversation];
    switch (text.toLowerCase()) {
      case 'journeys':
        await _offer(at);
      case 'stop' when chat != null:
        final why = await journeys.stop(chat.journey);
        await _say(at, why == null ? 'Stopped.' : 'Not stopped: $why');
      case _ when chat == null:
        await _say(at, 'Say "journeys" to open one.');
      case _:
        chat.said.add(text);
        final why = await journeys.say(chat.journey, text);
        if (why != null) {
          chat.said.remove(text);
          await _say(at, 'Not sent: $why');
        }
    }
  }

  Future<void> _press(
    _At at, {
    required String? card,
    required String? verb,
    required String? journey,
  }) async {
    final chat = _chats[at.conversation];
    switch (verb) {
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
            chat.queue = chat.queue
                .then((_) => _on(chat, e))
                .catchError((Object err) => log('teams journey: $err'));
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

  /// What one event of the journey becomes in the chat.
  Future<void> _on(_Chat chat, LoggedEvent e) async {
    switch (e.event) {
      case UserSaid(:final text):
        // What the owner said here comes back as the journey's own record.
        if (chat.said.remove(text)) break;
        await _flush(chat);
        await _say(chat.at, '_Said in the app:_ $text');
      case ReplyText(:final text):
        chat.reply.write(text);
      case ThinkingText() || ToolCalled():
        await _typing(chat);
      case StatusChanged(:final state, :final detail):
        if (state.busy) {
          await _typing(chat);
        } else {
          await _flush(chat);
          if (state == JourneyState.failed) {
            await _say(
              chat.at,
              'It failed${detail == null ? '.' : ': $detail'}',
            );
          }
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
        await _flush(chat);
        await _say(
          chat.at,
          'It offers this journey new tools: answer in the app.',
        );
      default:
        break;
    }
  }

  /// A question as a card, drawn by [draw]: with Yes and No until it is
  /// answered.
  Future<void> _ask(_Chat chat, int seq, _Draw draw) async {
    await _flush(chat);
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

  /// The reply so far, sent and cleared.
  Future<void> _flush(_Chat chat) async {
    final text = chat.reply.toString().trim();
    chat.reply.clear();
    for (final part in splitForTeams(text)) {
      await send(chat.at.serviceUrl, chat.at.conversation, {
        'type': 'message',
        'textFormat': 'markdown',
        'text': part,
      });
    }
  }

  Future<void> _typing(_Chat chat) async {
    final now = DateTime.now();
    if (now.difference(chat.typedAt) < typingEvery) return;
    chat.typedAt = now;
    try {
      await send(chat.at.serviceUrl, chat.at.conversation, {'type': 'typing'});
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

  static String _clip(String s) =>
      s.length <= 1500 ? s : '${s.substring(0, 1499)}…';

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

typedef _At = ({Uri serviceUrl, String conversation});

/// Draws a question's card: open while the answer is null, then answered.
typedef _Draw = Map<String, Object?> Function(bool? answer);

/// A chat with one journey open.
final class _Chat {
  _Chat(this.at, this.journey, {required this.after, required this.afterAt});

  final _At at;
  final RunId journey;

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

  /// What the owner said from this chat, until the journey records it.
  final said = <String>[];

  /// The reply so far in this turn: the model's text, as it streams.
  final reply = StringBuffer();

  /// The cards asking a question, by the seq of the event that asked it.
  final asks = <int, ({String card, _Draw draw})>{};

  DateTime typedAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> queue = Future.value();
  StreamSubscription<LoggedEvent>? events;
  Timer? retry;
  bool closed = false;

  Future<void> close() async {
    closed = true;
    retry?.cancel();
    await events?.cancel();
  }
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
