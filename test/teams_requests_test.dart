import 'dart:convert';

import 'package:is_effects/is_effects.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

final serviceUrl = Uri.parse('https://smba.trafficmanager.net/amer/');
const conversation = 'a:1personal;messageid=17';
final bot = SignIn.parse('test-bot')!;

void main() {
  TeamsPost post({String? replyToId, Uri? url}) => TeamsPost(
    serviceUrl: url ?? serviceUrl,
    conversation: conversation,
    replyToId: replyToId,
    activity: {'type': 'message', 'text': 'hi'},
  );

  test('a new message posts to the conversation, under the region', () {
    final r = teamsPostRequest(post(), bot);
    expect(r.origin, Origin.parse('https://smba.trafficmanager.net'));
    expect(r.method, Method.post);
    expect(
      r.path.value,
      '/amer/v3/conversations/a%3A1personal%3Bmessageid%3D17/activities',
    );
    expect(r.signIn, bot);
    expect(jsonDecode(r.body!), {'type': 'message', 'text': 'hi'});
  });

  group('the conversation path prefix', () {
    test('is the region, then the id percent-encoded with upper-case '
        'escapes', () {
      expect(
        teamsConversationPathPrefix(serviceUrl, conversation)!.value,
        '/amer/v3/conversations/a%3A1personal%3Bmessageid%3D17/',
      );
      expect(
        teamsConversationPathPrefix(
          Uri.parse('https://smba.trafficmanager.net/au'),
          '19:abc@thread.tacv2',
        )!.value,
        '/au/v3/conversations/19%3Aabc%40thread.tacv2/',
      );
    });

    test('begins every request built for the conversation', () {
      final prefix = teamsConversationPathPrefix(serviceUrl, conversation)!;
      for (final r in [
        teamsPostRequest(post(), bot),
        teamsPostRequest(post(replyToId: '1730881000000'), bot),
        teamsUpdateRequest(
          serviceUrl: serviceUrl,
          conversation: conversation,
          activityId: '1730881000000',
          activity: const {'type': 'message'},
          signIn: bot,
        ),
      ]) {
        expect(r.path.value, startsWith(prefix.value));
      }
    });

    test('never matches another conversation whose id it begins', () {
      final prefix = teamsConversationPathPrefix(serviceUrl, 'a:1')!;
      final other = teamsPostRequest(
        TeamsPost(
          serviceUrl: serviceUrl,
          conversation: 'a:12',
          activity: const {'type': 'message'},
        ),
        bot,
      );
      expect(other.path.value, isNot(startsWith(prefix.value)));
    });
  });

  test('a reply posts to the message it answers', () {
    final r = teamsPostRequest(post(replyToId: '1730881000000'), bot);
    expect(r.method, Method.post);
    expect(r.path.value, endsWith('/activities/1730881000000'));
  });

  test('an update puts to the message, carrying its id', () {
    final r = teamsUpdateRequest(
      serviceUrl: serviceUrl,
      conversation: conversation,
      activityId: 'card-1',
      activity: {'type': 'message'},
      signIn: bot,
    );
    expect(r.method, Method.put);
    expect(r.path.value, endsWith('/activities/card-1'));
    expect(jsonDecode(r.body!), {'type': 'message', 'id': 'card-1'});
  });

  test('a service URL with no region path, or no trailing slash', () {
    expect(
      teamsPostRequest(
        post(url: Uri.parse('https://x.example')),
        bot,
      ).path.value,
      startsWith('/v3/conversations/'),
    );
    expect(
      teamsPostRequest(
        post(url: Uri.parse('https://x.example/au')),
        bot,
      ).path.value,
      startsWith('/au/v3/conversations/'),
    );
  });

  test('a conversation id that would climb out of the path is refused', () {
    expect(
      () => teamsUpdateRequest(
        serviceUrl: serviceUrl,
        conversation: '..',
        activityId: 'card-1',
        activity: {'type': 'message'},
        signIn: bot,
      ),
      throwsArgumentError,
    );
  });

  test('the port stays with the site', () {
    final r = teamsPostRequest(
      post(url: Uri.parse('https://x.example:8443/au/')),
      bot,
    );
    expect(r.origin, Origin.parse('https://x.example:8443'));
  });

  test('refuses a service URL that is not https', () {
    expect(
      () => teamsPostRequest(post(url: Uri.parse('http://x.example/')), bot),
      throwsArgumentError,
    );
  });
}
