/// The Teams relay's check of a delivery, for is_relay's `RelayServer`:
/// the token from the headers alone, then the activity once the body is in
/// hand.
///
/// Every authentic activity is recorded, whatever its type: one no event is
/// read from is recorded too, and the reading admits nothing for it. An
/// invoke's response (a card press's acknowledgement, a dialog) goes out
/// with the 200 once the activity is recorded.
library;

import 'dart:typed_data';

import 'package:is_docking_station_api/is_docking_station_api.dart'
    show RelayedEventSource;
import 'package:is_relay/is_relay.dart';

import 'key_source.dart';
import 'teams_event_translator.dart';
import 'teams_gate.dart';

final class TeamsDeliveryCheck implements ChecksDeliveries<TeamsToken> {
  TeamsDeliveryCheck({required this.spec, required this.keys});

  final TeamsSourceSpec spec;

  /// Refreshed behind requests, never fetched for one: a request that
  /// arrives before any keys have is refused, and Teams sends it again.
  final BotFrameworkKeySource keys;

  @override
  RelayedEventSource get source => teamsEventSource;

  @override
  HeaderCheck<TeamsToken> checkHeaders(DeliveryHeaders headers, DateTime now) {
    final keySet = keys.current();
    if (keySet == null) {
      // Not the sender's fault: no key set has arrived from Microsoft yet.
      return const HeadersRefused(
        RefusalStatus.serviceUnavailable,
        'no keys yet',
      );
    }
    return switch (teamsToken(
      spec: spec,
      keys: keySet,
      headers: {'authorization': ?headers['authorization']},
      now: now,
    )) {
      TeamsTokenRefused(:final decision) => HeadersRefused(
        _refusal(decision.status),
        decision.reason,
      ),
      final TeamsToken token => HeadersVouch(token),
    };
  }

  @override
  BodyVerdict checkBody(TeamsToken vouched, Uint8List body) {
    final d = teamsGateBody(spec: spec, token: vouched, body: body);
    return switch (d.outcome) {
      TeamsGateOutcome.reject => Refuse(_refusal(d.status), d.reason),
      TeamsGateOutcome.trigger ||
      TeamsGateOutcome.ignore => Record(response: d.invokeResponse),
    };
  }

  /// The gate refuses with 400, 401, 403 or 413.
  static RefusalStatus _refusal(int status) => RefusalStatus.values.firstWhere(
    (s) => s.code == status,
    orElse: () => RefusalStatus.badRequest,
  );
}
