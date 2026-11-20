/// What CAM posts in answer to a conversation's events, as Teams messages:
/// the card saying a trajectory opened, and a model's reply.
///
/// A reply is an Adaptive Card per message, the reply's text in it, and a
/// footer saying how full the model's context is. A reply too long for one
/// message is split across several, in order, and only the last carries
/// the footer and any note that the reply was cut off.
///
/// teams_module is the one place these bytes are made: the airlock decides
/// the requests built here as they are, recording exactly what each one
/// sends, and knows nothing of Teams.
library;

import 'dart:convert';

import 'package:is_effects/is_effects.dart';

import 'teams_event.dart';
import 'teams_gate.dart';
import 'teams_post.dart';
import 'teams_requests.dart';

/// The most a message may weigh, encoded, by Microsoft's docs: about 28 KB.
/// Not yet measured against Teams.
const teamsMessageByteCap = 28000;

/// [reply] as the Teams messages it goes out as, in posting order, each
/// [teamsMessageByteCap] or less once encoded. Always at least one.
List<Map<String, Object?>> teamsReplyActivities(
  ModelReply reply, {
  int byteCap = teamsMessageByteCap,
}) {
  final cutOff = reply is CutOffReply;
  final footer = switch (reply.usage) {
    final usage? => contextFooter(usage),
    null => null,
  };
  Map<String, Object?> last(String text) =>
      _activity(text, cutOff: cutOff, footer: footer);
  // Every part is weighed as the last would be, footer and all, so a part
  // that fits stays fitting wherever it lands.
  bool fits(String text) =>
      utf8.encode(jsonEncode(last(text))).length <= byteCap;
  final parts = splitToFit(reply.text, fits);
  return [
    for (var i = 0; i < parts.length; i++)
      i == parts.length - 1
          ? last(parts[i])
          : _activity(parts[i], cutOff: false, footer: null),
  ];
}

/// The requests that post [reply] to the conversation [relayedEvent] came
/// from, signed as [signIn], in posting order. Null when [relayedEvent] is
/// not a Teams activity, so the airlock can refuse saying so.
///
/// [relayedEvent] is the activity's body as the relay recorded it, which
/// names the conversation and the regional endpoint that reaches it.
List<Request>? teamsReplyRequests({
  required List<int> relayedEvent,
  required ModelReply reply,
  required SignIn signIn,
}) {
  final event = _teamsEventOrNull(relayedEvent);
  if (event == null) return null;
  return [
    for (final activity in teamsReplyActivities(reply))
      _post(event, activity, signIn),
  ];
}

/// The card that says a trajectory opened in this conversation, with the
/// one action a person closes it by: a press read as
/// [CardActionVerb.close]. Teams shows when it was posted, so the card
/// names no time.
const Map<String, Object?> teamsTrajectoryOpenCard = {
  'type': 'message',
  'attachments': [
    {
      'contentType': 'application/vnd.microsoft.card.adaptive',
      'content': {
        r'$schema': 'http://adaptivecards.io/schemas/adaptive-card.json',
        'type': 'AdaptiveCard',
        'version': '1.5',
        'body': [
          {
            'type': 'TextBlock',
            'text': '● Open · trajectory started',
            'wrap': true,
          },
        ],
        'actions': [
          {
            'type': 'Action.Execute',
            'title': 'Close trajectory',
            'verb': 'close',
          },
        ],
      },
    },
  ],
};

/// The request that posts [teamsTrajectoryOpenCard] to the conversation
/// [relayedEvent] came from, signed as [signIn]. Null when [relayedEvent]
/// is not a Teams activity.
List<Request>? teamsTrajectoryOpenedRequests({
  required List<int> relayedEvent,
  required SignIn signIn,
}) {
  final event = _teamsEventOrNull(relayedEvent);
  if (event == null) return null;
  return [_post(event, teamsTrajectoryOpenCard, signIn)];
}

TeamsEvent? _teamsEventOrNull(List<int> relayedEvent) {
  try {
    return teamsRecordedEvent(relayedEvent);
  } on FormatException {
    return null;
  }
}

Request _post(TeamsEvent event, Map<String, Object?> activity, SignIn signIn) =>
    teamsPostRequest(
      TeamsPost(
        serviceUrl: event.serviceUrl,
        conversation: event.conversation,
        activity: activity,
      ),
      signIn,
    );

/// How full the model's context is after the call [usage] reports, such as
/// `context 152k of 200k (76%)`, or `context 152k` when the model's window
/// isn't known. Rounded up, never down: it is a warning.
String contextFooter(ModelUsage usage) {
  final used = usage.context;
  final window = usage.contextWindow;
  if (window == null || window <= 0) return 'context ${tokenCount(used)}';
  final percent = (used * 100 + window - 1) ~/ window;
  return 'context ${tokenCount(used)} of ${tokenCount(window)} ($percent%)';
}

/// [tokens] in thousands below a million and millions above, rounded up:
/// `152k`, `1.1M`, `2M`.
String tokenCount(int tokens) {
  final thousands = (tokens + 999) ~/ 1000;
  if (thousands < 1000) return '${thousands}k';
  final tenthsOfMillions = (tokens + 99999) ~/ 100000;
  final whole = tenthsOfMillions ~/ 10;
  final tenth = tenthsOfMillions % 10;
  return tenth == 0 ? '${whole}M' : '$whole.${tenth}M';
}

/// [text] in parts that each [fits], in order, which joined back with what
/// was cut between them give [text] again. Cut at a blank line where one
/// does, else at a line break, else between characters, never inside one.
/// One part when [text] fits whole, empty or not.
List<String> splitToFit(String text, bool Function(String part) fits) {
  if (fits(text)) return [text];
  final parts = <String>[];
  for (final paragraph in _pack(text.split('\n\n'), '\n\n', fits)) {
    if (fits(paragraph)) {
      parts.add(paragraph);
      continue;
    }
    for (final line in _pack(paragraph.split('\n'), '\n', fits)) {
      parts.addAll(fits(line) ? [line] : _byCharacters(line, fits));
    }
  }
  return parts;
}

/// [pieces] joined by [separator] into as few runs as [fits] allows. A
/// piece too big on its own is its own run, left for the caller to cut.
List<String> _pack(
  List<String> pieces,
  String separator,
  bool Function(String) fits,
) {
  final runs = <String>[];
  String? run;
  for (final piece in pieces) {
    final joined = run == null ? piece : '$run$separator$piece';
    if (fits(joined)) {
      run = joined;
    } else {
      if (run != null) runs.add(run);
      run = piece;
    }
  }
  if (run != null) runs.add(run);
  return runs;
}

/// [line] cut between characters into the longest runs that [fits]. A
/// character is a Unicode code point, so no cut lands inside one.
List<String> _byCharacters(String line, bool Function(String) fits) {
  final characters = line.runes.toList();
  final runs = <String>[];
  var start = 0;
  while (start < characters.length) {
    // The longest run from start that fits, found by halving.
    var low = start + 1, high = characters.length;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (fits(String.fromCharCodes(characters, start, mid))) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    runs.add(String.fromCharCodes(characters, start, low));
    start = low;
  }
  return runs;
}

/// One message: an Adaptive Card 1.5, the shape that rendered in every
/// tenant tried, holding [text], then the cut-off note and the [footer]
/// when there are any. No actions.
Map<String, Object?> _activity(
  String text, {
  required bool cutOff,
  required String? footer,
}) => {
  'type': 'message',
  'attachments': [
    {
      'contentType': 'application/vnd.microsoft.card.adaptive',
      'content': {
        r'$schema': 'http://adaptivecards.io/schemas/adaptive-card.json',
        'type': 'AdaptiveCard',
        'version': '1.5',
        'body': [
          {'type': 'TextBlock', 'text': text, 'wrap': true},
          if (cutOff)
            {
              'type': 'TextBlock',
              'text': '(reply cut off)',
              'wrap': true,
              'isSubtle': true,
            },
          if (footer != null)
            {
              'type': 'TextBlock',
              'text': footer,
              'wrap': true,
              'isSubtle': true,
            },
        ],
      },
    },
  ],
};
