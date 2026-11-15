import 'teams_event.dart';
import 'teams_ids.dart';

/// Which Entra user each Teams channel id `29:…` belongs to, as far as the
/// record says.
///
/// A quote names its author only by channel id, which names a person only
/// to this bot, so who wrote a quoted message is known only if they have
/// been heard from. Nothing is asked of Teams (Nick, 15 Nov): this holds
/// what has arrived, and nothing else.
///
/// A channel id names the same person in every chat with the bot, so one
/// of these serves every chat's [TeamsTranslator]: someone heard from in
/// one chat is known when quoted in another. Learning the same pair twice
/// changes nothing, so it can be given every event in the record, in order,
/// on a restart as well as live, and comes out the same.
final class TeamsAuthors {
  final _entraIds = <TeamsUserId, EntraObjectId>{};

  /// Notes who sent [event], when Teams named both their channel id and
  /// their Entra object id, each in its proper form.
  void learn(TeamsEvent event) {
    final from = switch (event.from) {
      final s? => TeamsUserId.parse(s),
      null => null,
    };
    final entra = switch (event.fromAadObjectId) {
      final s? => EntraObjectId.parse(s),
      null => null,
    };
    if (from != null && entra != null) _entraIds[from] = entra;
  }

  /// The Entra object id of the person Teams calls [user], or null when
  /// they haven't been heard from.
  EntraObjectId? entraIdOf(TeamsUserId user) => _entraIds[user];
}
