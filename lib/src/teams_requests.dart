/// A Teams message as a [Request]: described for a web driver to send, not
/// sent. The module names where the message goes and what it carries; the
/// airlock decides the request and the driver signs it with [SignIn]'s
/// token, so no secret is needed here.
///
/// The paths are the Bot Connector's:
/// `{serviceUrl}/v3/conversations/{conversation}/activities[/{id}]`. The
/// service URL's own path, the region (`/au/`, `/amer/`), goes in front.
library;

import 'dart:convert';

import 'package:is_effects/is_effects.dart';

import 'teams_post.dart';

/// [post] as a request: a new message, or a reply under
/// [TeamsPost.replyToId]. The driver's `Sent.created` is the new message's
/// id.
Request teamsPostRequest(TeamsPost post, SignIn signIn) => _request(
  Method.post,
  post.serviceUrl,
  post.conversation,
  post.replyToId,
  post.activity,
  signIn,
);

/// Replaces the bot's own message [activityId] with [activity]: how a card
/// changes after someone presses a button on it. Teams lets a bot edit only
/// its own messages.
Request teamsUpdateRequest({
  required Uri serviceUrl,
  required String conversation,
  required String activityId,
  required Map<String, Object?> activity,
  required SignIn signIn,
}) => _request(Method.put, serviceUrl, conversation, activityId, {
  ...activity,
  'id': activityId,
}, signIn);

/// Refuses a service URL that is not https: the driver adds the token to
/// the request, and it must never travel in the clear.
Request _request(
  Method method,
  Uri serviceUrl,
  String conversation,
  String? activityId,
  Map<String, Object?> activity,
  SignIn signIn,
) {
  // wire-ok: a URI scheme, checked against the one we accept.
  if (serviceUrl.scheme != 'https') {
    throw ArgumentError.value(serviceUrl, 'serviceUrl', 'is not https');
  }
  final origin = Origin.parse(
    Uri(
      scheme: serviceUrl.scheme,
      host: serviceUrl.host,
      port: serviceUrl.port,
    ).toString(),
  );
  if (origin == null) {
    throw ArgumentError.value(serviceUrl, 'serviceUrl', 'has no site');
  }
  final region = serviceUrl.path.endsWith('/')
      ? serviceUrl.path.substring(0, serviceUrl.path.length - 1)
      : serviceUrl.path;
  return Request(
    origin,
    method: method,
    path:
        '$region/v3/conversations/${Uri.encodeComponent(conversation)}'
        '/activities${activityId == null ? '' : '/${Uri.encodeComponent(activityId)}'}',
    signIn: signIn,
    headers: const {'content-type': 'application/json; charset=utf-8'},
    body: jsonEncode(activity),
  );
}
