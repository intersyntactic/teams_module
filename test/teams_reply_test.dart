import 'dart:convert';

import 'package:is_effects/is_effects.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// The TextBlocks of [activity]'s card, in order.
List<Map<String, Object?>> _blocks(Map<String, Object?> activity) {
  final attachment =
      (activity['attachments']! as List<Object?>).single!
          as Map<String, Object?>; // cast-ok: built by this package.
  final card =
      attachment['content']! as Map<String, Object?>; // cast-ok: as above.
  return [
    for (final b in card['body']! as List<Object?>) // cast-ok: as above.
      b! as Map<String, Object?>, // cast-ok: as above.
  ];
}

List<String> _texts(Map<String, Object?> activity) => [
  for (final b in _blocks(activity)) '${b['text']}',
];

int _bytes(Map<String, Object?> activity) =>
    utf8.encode(jsonEncode(activity)).length;

void main() {
  const usage = ModelUsage(
    input: 1200,
    cacheRead: 150000,
    output: 900,
    cacheCreation: 800,
    contextWindow: 200000,
  );

  group('the card', () {
    test('a finished reply: its text, then the footer, no actions', () {
      final [activity] = teamsReplyActivities(
        const FinishedReply(text: 'hi', usage: usage),
      );
      expect(activity['type'], 'message');
      expect(_texts(activity), ['hi', 'context 152k of 200k (76%)']);
      expect(_blocks(activity).last['isSubtle'], isTrue);
      expect(jsonEncode(activity), isNot(contains('actions')));
    });

    test('a cut-off reply says so, above the footer', () {
      final [activity] = teamsReplyActivities(
        const CutOffReply(text: 'half a', usage: usage),
      );
      expect(_texts(activity), [
        'half a',
        '(reply cut off)',
        'context 152k of 200k (76%)',
      ]);
    });

    test('no usage, no footer', () {
      final [activity] = teamsReplyActivities(const FinishedReply(text: 'hi'));
      expect(_texts(activity), ['hi']);
    });
  });

  group('the footer', () {
    test('rounds up, the count and the percentage', () {
      // 150,001 in context of 200,000 is 75.0005%: a warning reads 76.
      expect(
        contextFooter(
          const ModelUsage(
            input: 1,
            cacheRead: 150000,
            output: 0,
            contextWindow: 200000,
          ),
        ),
        'context 151k of 200k (76%)',
      );
    });

    test('counts what is in context, never the output', () {
      expect(
        contextFooter(
          const ModelUsage(input: 1000, cacheRead: 0, output: 999999),
        ),
        'context 1k',
      );
    });

    test('gives only the count when the window is not known', () {
      expect(
        contextFooter(const ModelUsage(input: 152000, cacheRead: 0, output: 0)),
        'context 152k',
      );
    });

    test('counts in thousands, then millions, rounded up', () {
      expect(tokenCount(0), '0k');
      expect(tokenCount(1), '1k');
      expect(tokenCount(999000), '999k');
      expect(tokenCount(999001), '1M');
      expect(tokenCount(1000000), '1M');
      expect(tokenCount(1000001), '1.1M');
      expect(tokenCount(2000000), '2M');
    });
  });

  group('a long reply', () {
    test('is split at blank lines, each part under the cap, the footer and '
        'cut-off note on the last only', () {
      final paragraphs = [for (var i = 0; i < 40; i++) 'p$i ${'x' * 400}'];
      final reply = CutOffReply(text: paragraphs.join('\n\n'), usage: usage);
      final parts = teamsReplyActivities(reply, byteCap: 4000);
      expect(parts.length, greaterThan(1));
      for (final p in parts) {
        expect(_bytes(p), lessThanOrEqualTo(4000));
      }
      for (final p in parts.take(parts.length - 1)) {
        expect(_texts(p), hasLength(1));
      }
      expect(_texts(parts.last).skip(1), [
        '(reply cut off)',
        'context 152k of 200k (76%)',
      ]);
      // Joined back at the blank lines it was cut at, it is the reply.
      expect([for (final p in parts) _texts(p).first].join('\n\n'), reply.text);
    });

    test('a paragraph too long alone is cut at its line breaks', () {
      final lines = [for (var i = 0; i < 30; i++) 'line $i ${'y' * 300}'];
      final text = lines.join('\n');
      final parts = splitToFit(text, (s) => s.length <= 2000);
      expect(parts.length, greaterThan(1));
      expect(parts.join('\n'), text);
      for (final p in parts) {
        expect(p.length, lessThanOrEqualTo(2000));
      }
    });

    test('a line too long alone is cut between characters, never inside '
        'one', () {
      // Each emoji is two UTF-16 units and four UTF-8 bytes.
      final text = '😀' * 1000;
      bool fits(String s) => utf8.encode(s).length <= 1001;
      final parts = splitToFit(text, fits);
      expect(parts.join(), text);
      for (final p in parts) {
        expect(fits(p), isTrue);
        // A cut inside a surrogate pair would not survive the round trip.
        expect(utf8.decode(utf8.encode(p)), p);
      }
      expect(parts.first.runes.length, 250);
    });

    test('a reply that fits is one part, even an empty one', () {
      expect(splitToFit('', (_) => true), ['']);
      expect(teamsReplyActivities(const FinishedReply(text: '')), hasLength(1));
    });
  });

  group('the requests', () {
    final signIn = SignIn.parse('cam-teams')!;

    test('post each part, in order, to the conversation the event came '
        'from', () {
      final event = utf8.encode(
        jsonEncode({
          ...message(),
          'conversation': {'id': '19:c1@thread.v2'},
        }),
      );
      final reply = FinishedReply(
        text: [for (var i = 0; i < 40; i++) 'p$i ${'x' * 2000}'].join('\n\n'),
        usage: usage,
      );
      final requests = teamsReplyRequests(
        relayedEvent: event,
        reply: reply,
        signIn: signIn,
      )!;
      final activities = teamsReplyActivities(reply);
      expect(requests, hasLength(activities.length));
      expect(requests.length, greaterThan(1));
      for (var i = 0; i < requests.length; i++) {
        final r = requests[i];
        expect(r.method, Method.post);
        expect(r.signIn, signIn);
        expect('${r.origin}', 'https://smba.trafficmanager.net');
        expect(
          '${r.path}',
          '/amer/v3/conversations/19%3Ac1%40thread.v2/activities',
        );
        expect(r.body, jsonEncode(activities[i]));
      }
    });

    test('are null for bytes that are not a Teams activity', () {
      expect(
        teamsReplyRequests(
          relayedEvent: utf8.encode('not json'),
          reply: const FinishedReply(text: 'hi'),
          signIn: signIn,
        ),
        isNull,
      );
      expect(
        teamsReplyRequests(
          relayedEvent: utf8.encode(jsonEncode({...message(), 'type': 'x'})),
          reply: const FinishedReply(text: 'hi'),
          signIn: signIn,
        ),
        isNull,
      );
    });
  });
}
