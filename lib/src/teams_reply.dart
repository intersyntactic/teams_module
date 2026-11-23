/// The Teams drawing of a reply: how a reply shows in a Teams conversation,
/// going out.
///
/// A reply is drawn as an Adaptive Card per message, its text in it, and at
/// the bottom a footer saying the turn and how full the model's context is,
/// with "Close trajectory" in the card's menu. A reply too long for one
/// message is split across several, in order, and only the last carries
/// the footer, the menu and any note that the reply was cut off.
///
/// teams_module is the one place these bytes are made: [drawTeamsReply]
/// draws them, and [postTeamsReplyDrawing], which `teams-reply-drawing`
/// prints, addresses and signs them as the requests that would post them,
/// to the conversation's reply endpoint as the logbook recorded it.
library;

import 'dart:convert';

import 'package:is_effects/is_effects.dart';
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;

import 'teams_event.dart' show CardActionVerb;
import 'teams_requests.dart';

/// The most a message may weigh, encoded, by Microsoft's docs: about 28 KB.
/// Not yet measured against Teams.
const teamsMessageByteCap = 28000;

/// The most messages one reply goes out as. Past it the reply is cut off at
/// the last message, which says so: each message is up to
/// [teamsMessageByteCap], and every byte sent is kept in the logbook too.
const teamsReplyMaxMessages = 10;

/// [reply] as the Teams messages it goes out as, in posting order, each
/// [teamsMessageByteCap] or less once encoded, the last closing
/// [trajectory]. Always at least one.
List<Map<String, Object?>> teamsReplyActivities(
  ModelReply reply, {
  required TrajectoryId trajectory,
  int byteCap = teamsMessageByteCap,
}) => drawTeamsReply(
  reply.text,
  trajectory: trajectory,
  footer: switch (reply.usage) {
    final usage? => contextFooter(usage),
    null => null,
  },
  cutOff: reply is CutOffReply,
  byteCap: byteCap,
);

/// The reply [text] drawn for Teams: the messages it shows as, in posting
/// order, each [byteCap] or less once encoded, the last carrying [footer],
/// the menu that closes [trajectory] and, when [cutOff] or when it takes
/// more than [maxMessages], a note that it was cut off. Always at least
/// one. Pure: the same inputs draw the same bytes.
List<Map<String, Object?>> drawTeamsReply(
  String text, {
  required TrajectoryId trajectory,
  String? footer,
  bool cutOff = false,
  int byteCap = teamsMessageByteCap,
  int? maxMessages,
}) {
  bool fitsAsLast(String part, {required bool cut}) =>
      utf8
          .encode(
            jsonEncode(
              _activity(part, closes: trajectory, cutOff: cut, footer: footer),
            ),
          )
          .length <=
      byteCap;
  // Every part is weighed as the last would be, footer and all, so a part
  // that fits stays fitting wherever it lands.
  var parts = splitToFit(text, (part) => fitsAsLast(part, cut: cutOff));
  var cut = cutOff;
  if (maxMessages != null && parts.length > maxMessages) {
    cut = true;
    parts = parts.sublist(0, maxMessages);
    // The last part must still fit once the cut-off note is in it.
    final last = parts.removeLast();
    parts.add(splitToFit(last, (part) => fitsAsLast(part, cut: true)).first);
  }
  return [
    for (var i = 0; i < parts.length; i++)
      i == parts.length - 1
          ? _activity(parts[i], closes: trajectory, cutOff: cut, footer: footer)
          : _activity(parts[i], closes: null, cutOff: false, footer: null),
  ];
}

/// The requests that would post the Teams drawing of the reply [text] to
/// the conversation at [replyEndpoint], signed as [signIn], in posting
/// order: the reply as [drawTeamsReply] draws it, at most
/// [teamsReplyMaxMessages] messages, closing [trajectory]. Addressing and
/// signing are not drawing; they are here until the sending driver takes
/// them. [replyEndpoint] is the conversation's as the logbook recorded it,
/// never worked out again here.
List<ProposedRequest> postTeamsReplyDrawing({
  required String text,
  required TrajectoryId trajectory,
  required AddressPrefix replyEndpoint,
  required SignIn signIn,
  String? footer,
}) => [
  for (final activity in drawTeamsReply(
    text,
    trajectory: trajectory,
    footer: footer,
    maxMessages: teamsReplyMaxMessages,
  ))
    teamsPostToEndpoint(
      replyEndpoint: replyEndpoint,
      activity: activity,
      signIn: signIn,
    ),
];

/// The footer under a reply: `turn 3 · context 152k of 200k (76%)`, either
/// half on its own, or null when there is neither.
String? replyFooter({int? turn, int? contextTokens, int? contextWindow}) {
  final halves = [
    if (turn != null) 'turn $turn',
    if (contextTokens != null) contextFooterOf(contextTokens, contextWindow),
  ];
  return halves.isEmpty ? null : halves.join(' · ');
}

/// How full the model's context is after the call [usage] reports, such as
/// `context 152k of 200k (76%)`, or `context 152k` when the model's window
/// isn't known. Rounded up, never down: it is a warning.
String contextFooter(ModelUsage usage) =>
    contextFooterOf(usage.context, usage.contextWindow);

/// [used] tokens of a [window], as [contextFooter] says it.
String contextFooterOf(int used, int? window) {
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
/// when there are any. A reply's last message [closes] its trajectory:
/// "Close trajectory" as a secondary action, which Teams draws in the
/// card's overflow menu rather than as a button, its data naming the
/// trajectory. A press is read as [CardActionVerb.close].
Map<String, Object?> _activity(
  String text, {
  required TrajectoryId? closes,
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
        if (closes != null)
          'actions': [
            {
              'type': 'Action.Execute',
              'title': 'Close trajectory',
              'verb': CardActionVerb.close.asSent,
              'data': {'trajectory': closes.hex},
              'mode': 'secondary',
            },
          ],
      },
    },
  ],
};
