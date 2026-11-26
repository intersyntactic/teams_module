/// The Teams relay's check of a delivery, for is_relay's projecting
/// `RelayServer`: the token from the headers alone, then the activity once
/// the body is in hand.
///
/// What is recorded is the activity's [TeamsEvent] projection, never its
/// body, and an activity of a kind the module has no case for is refused
/// unrecorded. An invoke's response (a card press's acknowledgement, a
/// dialog) goes out with the 200 once the projection is recorded.
library;

import 'dart:typed_data';

import 'package:is_docking_station_api/is_docking_station_api.dart'
    show RelayedEventSource;
import 'package:is_relay/is_relay.dart';

import 'key_source.dart';
import 'teams_event_translator.dart';
import 'teams_gate.dart';

final class TeamsDeliveryCheck
    implements ChecksAndProjectsDeliveries<TeamsToken> {
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
      TeamsTokenRefused(:final refusal) => HeadersRefused(
        refusal.status,
        refusal.reason,
      ),
      final TeamsToken token => HeadersVouch(token),
    };
  }

  @override
  ProjectedVerdict checkBody(TeamsToken vouched, Uint8List body) =>
      switch (teamsGateBody(spec: spec, token: vouched, body: body)) {
        TeamsActivityTaken(:final event, :final response) => RecordProjection(
          event.projection(),
          response: response,
        ),
        TeamsActivityRefused(:final refusal) => Refuse(
          refusal.status,
          refusal.reason,
        ),
      };
}
