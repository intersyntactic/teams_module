import 'package:is_annotation_shapes/is_annotation_shapes.dart'
    show ApprovedVerdict, HeldOffVerdict, VerdictOnShownMessage;
import 'package:is_docking_station/is_docking_station.dart';

import 'teams_event.dart';
import 'teams_gate.dart';
import 'teams_ids.dart';
import 'teams_translator.dart';

/// The Teams module's reading, for the docking station: what each event the
/// Teams relay recorded is, in the record's order.
///
/// It describes and decides nothing, since the docking station is what
/// admits events under trajectories (RULINGS): a message is [MessageSaid]
/// with the [UserSaid] made from it, CAM or a person added to a
/// conversation is [ActorsJoinedAddress], a press of Approve or Not yet on a
/// card is [ShownMessageJudged] for that card, and everything else is
/// [NothingToAdmit] for now:
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
final class TeamsReading implements ModuleReading<TeamsReadingState> {
  const TeamsReading();

  /// As the relay records it.
  @override
  String get source => 'teams';

  @override
  TeamsReadingState get start => TeamsReadingState.empty;

  @override
  (TeamsReadingState, EventReading) step(
    TeamsReadingState state,
    RelayedEvent recorded,
  ) {
    final TeamsEvent? event;
    try {
      event = teamsRecordedEvent(recorded.bytes);
    } on FormatException {
      // The gate took these bytes, so this is a body the gate and this
      // reading disagree about: nothing to admit, rather than a fold that
      // stops at it every time the docking station starts.
      return (state, const NothingToAdmit());
    }
    if (event == null) return (state, const NothingToAdmit());
    // Learnt first, so a person quoting themselves is named even when this
    // is the first the record has heard from them.
    final next = state.learnt(event);
    return (next, _read(event, next) ?? const NothingToAdmit());
  }

  static EventReading? _read(TeamsEvent event, TeamsReadingState state) {
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
    switch (event) {
      case TeamsMessage():
        final key = EventKey.parse('message:${event.id}');
        final node = teamsSaid(event, entraOf: state.entraIdOf);
        if (key == null || node == null) return null;
        return MessageSaid(
          addressInExternalSystem: address,
          containingAddress: containingAddress,
          key: key,
          node: node,
        );
      case TeamsConversationUpdate():
        final key = EventKey.parse('conversationUpdate:${event.id}');
        if (key == null) return null;
        return ActorsJoinedAddress.of(
          addressInExternalSystem: address,
          containingAddress: containingAddress,
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
        // Edit only reopens the choice on a card.
        final VerdictOnShownMessage? verdict = switch (event.verb) {
          CardActionVerb.approve => const ApprovedVerdict(),
          CardActionVerb.notYet => const HeldOffVerdict(),
          CardActionVerb.edit || null => null,
        };
        if (key == null || to == null || verdict == null) return null;
        return ShownMessageJudged(
          addressInExternalSystem: address,
          containingAddress: containingAddress,
          from: actor,
          key: key,
          to: to,
          verdict: verdict,
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
}

/// What the Teams reading carries from one event to the next: which Entra
/// user each Teams channel id belongs to, as far as the record says. A
/// quote names its author only by channel id, and so does a join, so
/// either is named only if that person has been heard from.
///
/// Never changed: [learnt] gives a new one when there is something new,
/// and this one otherwise, which is almost always.
final class TeamsReadingState {
  const TeamsReadingState._(this._entraIds);

  /// Before any event.
  static const empty = TeamsReadingState._({});

  final Map<TeamsUserId, EntraObjectId> _entraIds;

  /// The Entra object id of the person Teams calls [user], or null when
  /// they haven't been heard from.
  EntraObjectId? entraIdOf(TeamsUserId user) => _entraIds[user];

  /// This, with who sent [event], when Teams named both their channel id
  /// and their Entra object id.
  TeamsReadingState learnt(TeamsEvent event) {
    if ((event.from, event.fromAadObjectId) case (final from?, final entra?)
        when _entraIds[from] != entra) {
      return TeamsReadingState._(Map.unmodifiable({..._entraIds, from: entra}));
    }
    return this;
  }
}
