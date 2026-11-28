/// A Teams message as a [ProposedRequest]: described for a web driver to send, not
/// sent. The module names where the message goes and what it carries; the
/// airlock decides the request and the driver signs it with [SignIn]'s
/// token, so no secret is needed here.
///
/// The paths are the Bot Connector's:
/// `{serviceUrl}/v3/conversations/{conversation}/activities[/{id}]`. The
/// service URL's own path, the region (`/au/`, `/amer/`), goes in front.
library;

import 'dart:convert';

import 'package:is_web_request_vocabulary/is_web_request_vocabulary.dart'
    show Method, ProposedRequest;
import 'package:is_sign_in_vocabulary/is_sign_in_vocabulary.dart' show SignIn;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show AddressPrefix, Origin, PathPrefix, WebPath;

import 'teams_post.dart';

/// [post] as a request: a new message, or a reply under
/// [TeamsPost.replyToId]. The driver's `Sent.created` is the new message's
/// id.
ProposedRequest teamsPostRequest(TeamsPost post, SignIn signIn) => _request(
  Method.post,
  post.serviceUrl,
  post.conversation,
  post.replyToId,
  post.activity,
  signIn,
);

const _headers = {'content-type': 'application/json; charset=utf-8'};

/// Replaces the bot's own message [activityId] with [activity]: how a card
/// changes after someone presses a button on it. Teams lets a bot edit only
/// its own messages.
ProposedRequest teamsUpdateRequest({
  required Uri serviceUrl,
  required String conversation,
  required String activityId,
  required Map<String, Object?> activity,
  required SignIn signIn,
}) => _request(Method.put, serviceUrl, conversation, activityId, {
  ...activity,
  'id': activityId,
}, signIn);

/// The path every request to [conversation] on [serviceUrl] starts with:
/// the service URL's region, then `/v3/conversations/<conversation>/`.
///
/// A conversation id can be spelled in a path two ways (`19:…` and
/// `19%3A…`); [PathPrefix.covers] takes either, and the requests built here
/// and the reply endpoint recorded for the conversation both spell it this
/// one way: the id percent-encoded, escapes in upper case. Null when the id
/// would lead the path off the site.
PathPrefix? teamsConversationPathPrefix(Uri serviceUrl, String conversation) {
  final region = serviceUrl.path.endsWith('/')
      ? serviceUrl.path.substring(0, serviceUrl.path.length - 1)
      : serviceUrl.path;
  return PathPrefix.parse(
    '$region/v3/conversations/${Uri.encodeComponent(conversation)}/',
  );
}

/// Where a reply to [conversation] on [serviceUrl] goes: its origin and path
/// prefix, worked out once, when the event is read, and recorded. Null
/// unless both are: an https site and a path that stays on it.
AddressPrefix? teamsReplyEndpoint(Uri serviceUrl, String conversation) {
  final origin = teamsConversationOrigin(serviceUrl);
  final prefix = teamsConversationPathPrefix(serviceUrl, conversation);
  return origin == null || prefix == null
      ? null
      : AddressPrefix.of(origin, prefix);
}

/// The site every request to a conversation on [serviceUrl] goes to. Null
/// unless it is an https site: the driver adds the token to the request,
/// and it must never travel in the clear.
Origin? teamsConversationOrigin(Uri serviceUrl) {
  // wire-ok: a URI scheme, checked against the one we accept.
  if (serviceUrl.scheme != 'https') return null;
  return Origin.parse(
    Uri(
      scheme: serviceUrl.scheme,
      host: serviceUrl.host,
      port: serviceUrl.port,
    ).toString(),
  );
}

/// Refuses a service URL [teamsConversationOrigin] has no site for.
ProposedRequest _request(
  Method method,
  Uri serviceUrl,
  String conversation,
  String? activityId,
  Map<String, Object?> activity,
  SignIn signIn,
) {
  final origin = teamsConversationOrigin(serviceUrl);
  if (origin == null) {
    throw ArgumentError.value(serviceUrl, 'serviceUrl', 'is not an https site');
  }
  final prefix = teamsConversationPathPrefix(serviceUrl, conversation);
  final path = prefix == null
      ? null
      : WebPath.parse(
          '${prefix.value}activities'
          '${activityId == null ? '' : '/${Uri.encodeComponent(activityId)}'}',
        );
  if (path == null) {
    throw ArgumentError.value(conversation, 'conversation', 'leaves the site');
  }
  return ProposedRequest(
    origin,
    method: method,
    path: path,
    signIn: signIn,
    headers: _headers,
    body: jsonEncode(activity),
  );
}
