/// Speaks as the bot: posts, replies to and edits messages through the Bot
/// Connector, the REST service Teams bots send through.
///
/// This is the one piece that holds the bot's secret. With the app id and
/// secret it asks Microsoft's sign-in service for a token that says "I am
/// this bot", good for about an hour, and shows that token on every call.
/// The relay never needs it: checking a delivery takes only public keys.
/// So the secret lives wherever the sending side runs, and nowhere else.
///
/// The Connector can write but not read: it has no call that fetches a
/// message.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checked_json/checked_json.dart';

/// An HTTP call's outcome: the status and the body as text.
typedef HttpResult = ({int status, String body});

/// Makes one HTTP call. Injected, so the connector is testable without a
/// network.
typedef HttpCall = Future<HttpResult> Function(
  String method,
  Uri url,
  Map<String, String> headers,
  String body,
);

/// A call the Connector or the sign-in service refused.
final class BotConnectorException implements Exception {
  BotConnectorException(this.what, this.status, this.body);
  final String what;
  final int status;

  /// Microsoft's error body. It names what went wrong and carries no secret.
  final String body;

  @override
  String toString() => 'BotConnectorException: $what: $status $body';
}

final class BotConnector {
  BotConnector({
    required this.appId,
    required String secret,
    required this.tenantId,
    HttpCall? http,
    DateTime Function()? now,
  }) : _secret = secret,
       _http = http ?? httpCall,
       _now = now ?? DateTime.now {
    if (appId.isEmpty || secret.isEmpty || tenantId.isEmpty) {
      throw ArgumentError('app id, secret and tenant id are all required');
    }
  }

  final String appId;

  /// The tenant the bot is registered in: the sign-in authority for its
  /// token. A single-tenant bot's token comes from its own tenant.
  final String tenantId;

  final String _secret;
  final HttpCall _http;
  final DateTime Function() _now;

  String? _token;
  DateTime? _tokenUntil;

  /// The scope a Connector token is for.
  static const scope = 'https://api.botframework.com/.default';

  /// Posts [activity] into the conversation; the new message's id.
  Future<String> send(
    Uri serviceUrl,
    String conversation,
    Map<String, Object?> activity,
  ) async => _id(
    await _call('POST', _url(serviceUrl, conversation, null), activity, 'send'),
  );

  /// Posts [activity] as a reply to [activityId]; the new message's id.
  Future<String> reply(
    Uri serviceUrl,
    String conversation,
    String activityId,
    Map<String, Object?> activity,
  ) async => _id(
    await _call(
      'POST',
      _url(serviceUrl, conversation, activityId),
      activity,
      'reply',
    ),
  );

  /// Replaces the bot's own message [activityId] with [activity]: how a
  /// card changes after someone presses a button on it. Teams lets a bot
  /// edit only its own messages.
  Future<void> update(
    Uri serviceUrl,
    String conversation,
    String activityId,
    Map<String, Object?> activity,
  ) => _call('PUT', _url(serviceUrl, conversation, activityId), {
    ...activity,
    'id': activityId,
  }, 'update');

  Future<String> _call(
    String method,
    Uri url,
    Map<String, Object?> activity,
    String what,
  ) async {
    final r = await _http(method, url, {
      'authorization': 'Bearer ${await _bearer()}',
      'content-type': 'application/json; charset=utf-8',
    }, jsonEncode(activity));
    if (r.status < 200 || r.status > 299) {
      throw BotConnectorException(what, r.status, r.body);
    }
    return r.body;
  }

  /// A Connector token, fetched again five minutes before it would expire
  /// rather than at the moment it does, so a call never carries one that
  /// lapses in flight.
  Future<String> _bearer() async {
    final until = _tokenUntil;
    if (_token != null && until != null && _now().isBefore(until)) {
      return _token!;
    }
    final r = await _http(
      'POST',
      Uri.https(
        'login.microsoftonline.com',
        '/${Uri.encodeComponent(tenantId)}/oauth2/v2.0/token',
      ),
      {'content-type': 'application/x-www-form-urlencoded'},
      Uri(
        queryParameters: {
          'grant_type': 'client_credentials',
          'client_id': appId,
          'client_secret': _secret,
          'scope': scope,
        },
      ).query,
    );
    if (r.status != 200) throw BotConnectorException('token', r.status, r.body);
    final t = JsonObject.decode(r.body);
    _token = t.string('access_token');
    _tokenUntil = _now().add(
      Duration(seconds: t.integer('expires_in')) - const Duration(minutes: 5),
    );
    return _token!;
  }

  /// `{serviceUrl}/v3/conversations/{conversation}/activities[/{id}]`.
  ///
  /// Refuses a service URL that is not https: the token rides on every
  /// call, and must never travel in the clear. Where the URL came from is
  /// the gate's business: it matched the activity's service URL against
  /// the signed token's own claim before any doorbell rang.
  static Uri _url(Uri serviceUrl, String conversation, String? activityId) {
    if (serviceUrl.scheme != 'https') {
      throw ArgumentError.value(serviceUrl, 'serviceUrl', 'is not https');
    }
    final base = serviceUrl.path.endsWith('/')
        ? serviceUrl.path
        : '${serviceUrl.path}/';
    return serviceUrl.replace(
      path:
          '${base}v3/conversations/${Uri.encodeComponent(conversation)}'
          '/activities${activityId == null ? '' : '/${Uri.encodeComponent(activityId)}'}',
    );
  }

  static String _id(String body) => JsonObject.decode(body).string('id');
}

/// [HttpCall] over `dart:io`, with a ten-second limit on each step.
Future<HttpResult> httpCall(
  String method,
  Uri url,
  Map<String, String> headers,
  String body,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.openUrl(method, url);
    headers.forEach(req.headers.set);
    req.add(utf8.encode(body));
    final res = await req.close().timeout(const Duration(seconds: 10));
    final text = await res
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 10));
    return (status: res.statusCode, body: text);
  } finally {
    client.close();
  }
}
