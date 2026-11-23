import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_annotation_shapes/is_annotation_shapes.dart'
    show ApprovedVerdict, HeldOffVerdict, VerdictOnShownMessage;
import 'package:is_docking_station_api/is_docking_station_api.dart';

import 'teams_event.dart';
import 'teams_gate.dart';
import 'teams_ids.dart';
import 'teams_said.dart';

/// The Teams module's translator, for the docking station: what each event
/// the Teams relay recorded is, in the docking station's terms, in the
/// logbook's order.
///
/// It describes and decides nothing, since the docking station is what
/// admits events under trajectories (RULINGS): a message is [MessageSaid]
/// with the [UserSaid] made from it, CAM or a person added to a
/// conversation is [ActorsJoinedAddress], a press of Approve or Not yet on a
/// card is [ShownMessageJudged] for that card, a press of Close, or the
/// "Close trajectory" message action submitted with its toggle on, is
/// [PersonAskedToCloseTrajectory] naming that card or message, and
/// everything else is [NothingToAdmit] for now:
///
/// - an `installationUpdate`, which Teams sends beside the
///   `conversationUpdate` of the same join, so one join is read once;
/// - an edit or a delete, until conversation_shapes has a shape for what a
///   message became;
/// - a press of Edit, which only reopens the choice on a card, and any verb
///   the cards don't send. No card takes a typed correction yet; when one
///   does, what was typed goes into [ProposedCorrectionVerdict] as text, and
///   the crux reads it as the shown shape's value.
///
/// An address is Teams' conversation id as Teams sends it. In a channel
/// that names a thread, `<channel>;messageid=<the thread's first post>`, so
/// each thread is an address of its own, and an answer sent back to it
/// lands in the thread; its [AdmissibleEvent.containingAddress] is its channel, the
/// mission whose trajectory it is (Nick, 15 Nov 21:00 and 21:03).
///
/// Event keys: `message:<id>` for something said,
/// `conversationUpdate:<id>` for a join, and `invoke:<id>` for a press. Teams
/// sends a redelivery with the same activity id, so the two events it makes
/// share a key; two activities have two.
final class TeamsEventTranslator
    implements TranslatesRelayedEvents<TeamsEventTranslatorState> {
  const TeamsEventTranslator();

  /// As the relay records it.
  @override
  String get source => 'teams';

  @override
  TeamsEventTranslatorState get start => TeamsEventTranslatorState.empty;

  @override
  (TeamsEventTranslatorState, TranslatedEvent) step(
    TeamsEventTranslatorState state,
    RelayedEvent recorded,
  ) {
    final TeamsEvent? event;
    try {
      event = teamsRecordedEvent(recorded.bytes);
    } on FormatException {
      // The gate took these bytes, so this is a body the gate and this
      // translator disagree about: nothing to admit, rather than a fold that
      // stops at it every time the docking station starts.
      return (state, const NothingToAdmit());
    }
    if (event == null) return (state, const NothingToAdmit());
    // Learnt first, so a person quoting themselves is named even when this
    // is the first the logbook has heard from them.
    final next = state.learnt(event);
    return (next, _read(event, next) ?? const NothingToAdmit());
  }

  static TranslatedEvent? _read(
    TeamsEvent event,
    TeamsEventTranslatorState state,
  ) {
    final address = AddressInExternalSystem.parse(
      'teams:${event.conversation}',
    );
    if (address == null) return null;
    // A thread sits inside its channel. A team-wide event arrives in the
    // team's first channel itself, which sits inside nothing.
    final containingAddress = switch (event.channel) {
      final c? when c != event.conversation => AddressInExternalSystem.parse(
        'teams:$c',
      ),
      _ => null,
    };
    // The gate held the token's audience to the activity's recipient, so
    // this is the bot Teams verified it was sent to.
    final addressedTo = teamsBotActor(event.tenant, event.bot);
    switch (event) {
      case TeamsMessage():
        final key = EventKey.parse('message:${event.id}');
        final node = teamsSaid(event, entraOf: state.entraIdOf);
        if (key == null || node == null) return null;
        return MessageSaid(
          addressInExternalSystem: address,
          containingAddress: containingAddress,
          addressedTo: addressedTo,
          key: key,
          node: node,
        );
      case TeamsConversationUpdate():
        final key = EventKey.parse('conversationUpdate:${event.id}');
        if (key == null) return null;
        return ActorsJoinedAddress.of(
          addressInExternalSystem: address,
          containingAddress: containingAddress,
          addressedTo: addressedTo,
          from: event.actor,
          key: key,
          joiners: [
            for (final user in event.added)
              ?teamsActor(
                event.tenant,
                user: user,
                entra: state.entraIdOf(user),
              ),
          ],
        );
      case TeamsCardAction(:final card?, :final actor?):
        final key = EventKey.parse('invoke:${event.id}');
        final to = TeamsMessageRef.of(event.conversation, card)?.source;
        if (key == null || to == null) return null;
        ShownMessageJudged judged(VerdictOnShownMessage verdict) =>
            ShownMessageJudged(
              addressInExternalSystem: address,
              containingAddress: containingAddress,
              addressedTo: addressedTo,
              from: actor,
              key: key,
              to: to,
              verdict: verdict,
            );
        return switch (event.verb) {
          CardActionVerb.approve => judged(const ApprovedVerdict()),
          CardActionVerb.notYet => judged(const HeldOffVerdict()),
          CardActionVerb.close => PersonAskedToCloseTrajectory(
            addressInExternalSystem: address,
            containingAddress: containingAddress,
            addressedTo: addressedTo,
            from: actor,
            key: key,
            message: to,
          ),
          // Edit only reopens the choice on a card.
          CardActionVerb.edit || null => null,
        };
      case TeamsMessageActionSubmit(
            command: closeTrajectoryCommandId,
            :final messageRef?,
            :final actor?,
          )
          when _confirmed(event.data):
        final key = EventKey.parse('invoke:${event.id}');
        if (key == null) return null;
        return PersonAskedToCloseTrajectory(
          addressInExternalSystem: address,
          containingAddress: containingAddress,
          addressedTo: addressedTo,
          from: actor,
          key: key,
          message: messageRef.source,
        );
      case TeamsCardAction() ||
          TeamsMessageUpdate() ||
          TeamsMessageDelete() ||
          TeamsInvoke() ||
          TeamsMessageActionSubmit() ||
          TeamsInstallationUpdate():
        return null;
    }
  }

  /// Whether the close action's toggle was on. Teams' encoding of a
  /// submitted toggle is not yet measured, so a JSON true and the text
  /// `true` both count.
  static bool _confirmed(JsonObject? data) =>
      // wire-ok: Teams' submitted toggle value, read once here.
      switch (data?.raw(closeTrajectoryConfirmParameter)) {
        true || 'true' => true,
        _ => false,
      };
}

/// What the Teams translator carries from one event to the next: which Entra
/// user each Teams channel id belongs to, as far as the logbook says. A
/// quote names its author only by channel id, and so does a join, so
/// either is named only if that person has been heard from.
///
/// Never changed: [learnt] gives a new one when there is something new,
/// and this one otherwise, which is almost always.
final class TeamsEventTranslatorState {
  const TeamsEventTranslatorState._(this._entraIds);

  /// Before any event.
  static const empty = TeamsEventTranslatorState._({});

  final Map<TeamsUserId, EntraObjectId> _entraIds;

  /// The Entra object id of the person Teams calls [user], or null when
  /// they haven't been heard from.
  EntraObjectId? entraIdOf(TeamsUserId user) => _entraIds[user];

  /// This, with who sent [event], when Teams named both their channel id
  /// and their Entra object id.
  TeamsEventTranslatorState learnt(TeamsEvent event) {
    if ((event.from, event.fromAadObjectId) case (final from?, final entra?)
        when _entraIds[from] != entra) {
      return TeamsEventTranslatorState._(
        Map.unmodifiable({..._entraIds, from: entra}),
      );
    }
    return this;
  }
}
