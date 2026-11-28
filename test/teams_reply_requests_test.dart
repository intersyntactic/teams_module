import 'dart:convert';

import 'package:is_effects/is_effects.dart';
import 'package:is_conversation_vocabulary/is_conversation_vocabulary.dart';
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

final trajectory = TrajectoryId.parse('a1' * 32)!;
final to = RepliesUnderWebAddress(
  teamsReplyEndpoint(
    Uri.parse('https://smba.trafficmanager.net/amer/'),
    '19:c1@thread.v2',
  )!,
);
const writer = TeamsReplyRequests();

ReplyContent content(String text, {String? footer}) => ReplyContent(
  text: ReplyText.parse(text)!,
  footer: footer == null ? null : ReplyText.parse(footer),
);

void main() {
  group('draw', () {
    test('posts each part, in order, under the endpoint, with no sign-in, '
        'keeping the body for its id', () {
      final text = [for (var i = 0; i < 4; i++) 'p$i ${'x' * 20000}']
          .join('\n\n');
      const footer = 'turn 3 · context 152k of 200k (76%)';
      final requests = writer.draw(
        to,
        trajectory,
        content(text, footer: footer),
      );
      final activities = drawTeamsReply(
        text,
        trajectory: trajectory,
        footer: footer,
        maxMessages: teamsReplyMaxMessages,
      );
      expect(requests.length, greaterThan(1));
      expect(requests, hasLength(activities.length));
      for (var i = 0; i < requests.length; i++) {
        final r = requests[i];
        expect(r.method, Method.post);
        expect(r.signIn, isNull);
        expect(r.keep, BodyToKeep.text);
        expect('${r.origin}', 'https://smba.trafficmanager.net');
        expect(
          '${r.path}',
          '/amer/v3/conversations/19%3Ac1%40thread.v2/activities',
        );
        expect(to.admitsAddress(r.origin, r.path), isTrue);
        expect(r.body, jsonEncode(activities[i]));
      }
    });

    test('is built from its inputs alone: the same inputs, the same '
        'requests, every field', () {
      final text = [for (var i = 0; i < 30; i++) 'p$i ${'é' * 1500}']
          .join('\n\n');
      String described() => jsonEncode([
        for (final r in writer.draw(to, trajectory, content(text)))
          encodeProposedRequest(r),
      ]);
      expect(described(), described());
    });

    test('closes the trajectory it is given on the last card only', () {
      final text = [for (var i = 0; i < 3; i++) 'p$i ${'x' * 20000}']
          .join('\n\n');
      final bodies = [
        for (final r in writer.draw(to, trajectory, content(text))) r.body!,
      ];
      expect(bodies.length, greaterThan(1));
      expect(bodies.last, contains(trajectory.hex));
      for (final b in bodies.take(bodies.length - 1)) {
        expect(b, isNot(contains(trajectory.hex)));
      }
    });

    test('stops at teamsReplyMaxMessages, the last saying it was cut off', () {
      final text = [for (var i = 0; i < 40; i++) 'p$i ${'x' * 20000}']
          .join('\n\n');
      final requests = writer.draw(to, trajectory, content(text));
      expect(requests, hasLength(teamsReplyMaxMessages));
      expect(requests.last.body, contains('(reply cut off)'));
    });
  });

  group('posted', () {
    test('is Ran with the id the Bot Connector answered', () {
      final outcome = writer.posted(
        const WebResponse(
          status: 201,
          body: TextBody('{"id":"1794969959813"}'),
        ),
      );
      expect(outcome, isA<Ran<ServerAssignedMessageId>>());
      expect(
        (outcome as Ran<ServerAssignedMessageId>).output.value,
        '1794969959813',
      );
    });

    test('is NothingRan for a 4xx, saying why', () {
      final outcome = writer.posted(
        const WebResponse(status: 403, refusedBecause: 'BotNotInConversation'),
      );
      expect(outcome, isA<NothingRan>());
      expect((outcome as NothingRan).why, contains('403'));
      expect(outcome.why, contains('BotNotInConversation'));
    });

    test('is NothingRan for a 429: throttled before anything posted, as '
        'slack_module reads it', () {
      final outcome = writer.posted(const WebResponse(status: 429));
      expect(outcome, isA<NothingRan>());
      expect((outcome as NothingRan).why, contains('429'));
    });

    test('is StoppedPartway with nothing done when it cannot be told', () {
      for (final response in [
        const WebResponse(status: 502),
        const WebResponse(status: 200),
        const WebResponse(status: 200, body: TextBody('not json')),
        const WebResponse(status: 200, body: TextBody('{"id":""}')),
        const WebResponse(status: 200, body: TextBody('{"id":7}')),
        const WebResponse(status: 200, body: TextBody('{}')),
      ]) {
        final outcome = writer.posted(response);
        expect(outcome, isA<StoppedPartway<ServerAssignedMessageId>>());
        expect(
          (outcome as StoppedPartway<ServerAssignedMessageId>).done,
          isNull,
        );
      }
    });
  });
}
