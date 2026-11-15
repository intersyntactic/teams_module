import 'package:is_docking_port/is_docking_port.dart';

import 'teams_event.dart';
import 'teams_gate.dart';
import 'teams_ids.dart';
import 'teams_translator.dart';

/// The Teams module's reading, for the docking port: what each arrival from
/// the Teams relay is, in the record's order.
///
/// It describes and decides nothing (RULINGS, "The docking port admits
/// arrivals under journey paths"): a message is [Said] with the [UserSaid]
/// made from it, CAM or a person added to a conversation is [Joined], and
/// everything else is [NothingToAdmit] for now:
///
/// - an `installationUpdate`, which Teams sends beside the
///   `conversationUpdate` of the same join, so one join is read once;
/// - an edit or a delete, until conversation_shapes has a shape for what a
///   message became;
/// - a card action, until the contract has a reading for one.
///
/// A conversation is Teams' conversation id as Teams sends it. In a channel
/// that names a thread, `<channel>;messageid=<the thread's first post>`, so
/// each thread is a conversation of its own (Nick, 15 Nov 21:00), and an
/// answer sent back to it lands in the thread.
///
/// Arrival keys: `message:<id>` for something said, and
/// `conversationUpdate:<id>` for a join. Teams sends a redelivery with the
/// same activity id, and two activities with two.
final class TeamsReading implements ModuleReading<TeamsReadingState> {
  const TeamsReading();

  /// As the relay records it.
  @override
  String get source => 'teams';

  @override
  TeamsReadingState get start => TeamsReadingState.empty;

  @override
  (TeamsReadingState, Reading) step(TeamsReadingState state, Arrival arrival) {
    final TeamsEvent? event;
    try {
      event = teamsWitnessedEvent(arrival.bytes);
    } on FormatException {
      // The gate took these bytes, so this is a body the gate and this
      // reading disagree about: nothing to admit, rather than a fold that
      // stops at it every time the docking port starts.
      return (state, const NothingToAdmit());
    }
    if (event == null) return (state, const NothingToAdmit());
    // Learnt first, so a person quoting themselves is named even when this
    // is the first the record has heard from them.
    final next = state.learnt(event);
    return (next, _read(event, next) ?? const NothingToAdmit());
  }

  static Reading? _read(TeamsEvent event, TeamsReadingState state) {
    final conversation = Conversation.parse('teams:${event.conversation}');
    if (conversation == null) return null;
    switch (event) {
      case TeamsMessage():
        final key = ArrivalKey.parse('message:${event.id}');
        final node = teamsSaid(event, entraOf: state.entraIdOf);
        if (key == null || node == null) return null;
        return Said(conversation: conversation, key: key, node: node);
      case TeamsConversationUpdate():
        final key = ArrivalKey.parse('conversationUpdate:${event.id}');
        if (key == null) return null;
        return Joined.of(
          conversation: conversation,
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
      default:
        return null;
    }
  }
}

/// What the Teams reading carries from one arrival to the next: which Entra
/// user each Teams channel id belongs to, as far as the record says. A
/// quote names its author only by channel id, and so does a join, so
/// either is named only if that person has been heard from.
///
/// Never changed: [learnt] gives a new one when there is something new,
/// and this one otherwise, which is almost always.
final class TeamsReadingState {
  const TeamsReadingState._(this._entraIds);

  /// Before any arrival.
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
