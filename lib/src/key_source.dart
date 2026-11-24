/// Where the gate's keys come from: Microsoft's OpenID document, then the
/// key set it names.
///
/// Microsoft asks a bot to refresh its copy "at least once every 24 hours".
/// This refreshes every [BotFrameworkKeySource.maxAge] (12 hours by default)
/// without making anyone wait: a request that finds the keys old is checked
/// against them while the refresh runs behind it. No request ever waits on
/// a fetch; one that arrives before any keys have is refused, and the relay
/// fetches once at boot.
library;

import 'dart:async';

import 'package:checked_json/checked_json.dart';

import 'bot_framework_keys.dart';

final class BotFrameworkKeySource {
  BotFrameworkKeySource({
    required this.get,
    DateTime Function()? now,
    this.maxAge = const Duration(hours: 12),
    this.retryAfter = const Duration(minutes: 1),
    Uri? metadata,
    this.log = _ignore,
  }) : _now = now ?? DateTime.now,
       metadata = metadata ?? defaultMetadata;

  /// The Bot Connector's OpenID document. Microsoft: "This is a static URL
  /// that you can hardcode."
  static final defaultMetadata = Uri.parse(
    'https://login.botframework.com/v1/.well-known/openidconfiguration',
  );

  /// Fetches a URL's body as text, throwing an [Exception] on failure.
  final Future<String> Function(Uri url) get;

  final Uri metadata;

  /// How long a fetched set is used before it is fetched again.
  final Duration maxAge;

  /// How long after a failed fetch the next is tried, so a Microsoft outage
  /// does not become one fetch per request.
  final Duration retryAfter;

  final void Function(String line) log;

  final DateTime Function() _now;

  BotFrameworkKeys? _keys;
  DateTime? _fetchedAt;
  DateTime? _failedAt;
  Future<void>? _refreshing;

  /// The keys to check a token against now, or null when none have
  /// arrived. When the set is older than [maxAge], or there is none and the
  /// last failure is older than [retryAfter], a refresh starts behind it;
  /// nothing waits on it.
  BotFrameworkKeys? current() {
    final now = _now();
    final fresh = _fetchedAt != null && now.difference(_fetchedAt!) < maxAge;
    final waiting =
        _failedAt != null && now.difference(_failedAt!) < retryAfter;
    if (!fresh && !waiting) unawaited(refresh());
    return _keys;
  }

  /// Fetches the keys, or joins the fetch already running, and returns the
  /// set it leaves: for the relay's boot, before it takes requests.
  Future<BotFrameworkKeys?> refresh() async {
    await (_refreshing ??= _refresh().whenComplete(() => _refreshing = null));
    return _keys;
  }

  Future<void> _refresh() async {
    try {
      final jwks = Uri.parse(
        JsonObject.decode(await get(metadata)).string('jwks_uri'),
      );
      // wire-ok: a URI scheme, checked against the one we accept.
      if (jwks.scheme != 'https') {
        throw FormatException('jwks_uri is not https: $jwks');
      }
      _keys = BotFrameworkKeys.parse(JsonObject.decode(await get(jwks)));
      _fetchedAt = _now();
      _failedAt = null;
    } on Exception catch (e) {
      // The old set, if there is one, stays in use: a key Microsoft has
      // since rotated out is refused by the gate anyway once it expires.
      _failedAt = _now();
      log('teams keys: refresh failed: $e');
    }
  }

  static void _ignore(String line) {}
}
