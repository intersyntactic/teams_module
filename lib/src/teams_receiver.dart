import 'package:checked_json/checked_json.dart';
import 'package:is_annotation_shapes/is_annotation_shapes.dart';
import 'package:is_shapes/is_shapes.dart';

/// What one doorbell writes, in the order the journey path takes it: a [seen], then
/// the approvals [withdrawn], then an [approve].
final class Annotations {
  const Annotations({this.seen, this.withdrawn = const [], this.approve});

  /// A doorbell that writes nothing.
  static const none = Annotations();

  /// The mark that the presser considered the version on the card.
  final Seen? seen;

  /// The presser's standing approvals of that version, taken back.
  final List<Withdraw<Approve>> withdrawn;

  /// An approval of the version on the card.
  final Approve? approve;

  /// Every node to append, in order.
  List<Object> get inOrder => [?seen, ...withdrawn, ?approve];
}

/// Turns Teams doorbells into annotation shapes: Approve on a card becomes an
/// [Approve], and Not yet a [Seen] and the withdrawals it asks for
/// (https://github.com/intersyntactic/teams_module/issues/1#issuecomment-6681468624).
///
/// It knows two things, each from its source. Which node a card shows, and in
/// which conversation, from the cards it was told it [show]s: a press names
/// its card by activity id and its verb, and the data on a card is not read,
/// since it comes back from the Teams client and a client can be made to send
/// any. And what each actor has written, from the nodes the journey path
/// [delivered] to it, each with its exact id. Whether two nodes say the same
/// thing is the journey path's to answer, as [sameVersion].
///
/// So a card is drawn from what is written, never from the last button
/// pressed on it: an approval stands for every pass that says the same, so
/// every card showing that version says so ([stanceOf], [cardsLike]).
final class TeamsReceiver {
  TeamsReceiver({required this.sameVersion, required this.log});

  /// Whether the nodes at two exact ids say the same thing: the same shape
  /// with the same fields, wherever each sits in the tree.
  final bool Function(TurnId a, TurnId b) sameVersion;

  /// Where a doorbell that writes nothing says why. The reason, never the
  /// content.
  final void Function(String) log;

  final _showing = <String, ({String conversation, Target target})>{};
  final _standing = <TurnId, Approve>{};
  final _seen = <Seen>[];

  /// The card with activity id [card], sent to [conversation], now shows the
  /// node at [target].
  void show(String card, Target target, {required String conversation}) =>
      _showing[card] = (conversation: conversation, target: target);

  /// The node card [card] shows, or null for a card it was never shown.
  Target? targetOf(String card) => _showing[card]?.target;

  /// Takes in a node the journey path delivered, named by its exact [id].
  void delivered(TurnId id, Object node) {
    switch (node) {
      case Approve():
        _standing[id] = node;
      case Withdraw<Approve>(:final target, :final by):
        // A withdrawal counts only from the approval's own author.
        if (_standing[target]?.by == by) _standing.remove(target);
      case Seen():
        _seen.add(node);
    }
  }

  /// Where [by] stands on the version of the node at [exact], from every pass
  /// that says the same: approved while any approval of theirs stands, held
  /// off when they have seen it and none stands, and open otherwise.
  Stance stanceOf(ActorId by, TurnId exact) {
    bool ofIt(Target t) => sameVersion(t.exact, exact);
    if (_standing.values.any((a) => a.by == by && ofIt(a.target))) {
      return Stance.approved;
    }
    if (_seen.any((s) => s.by == by && ofIt(s.target))) return Stance.heldOff;
    return Stance.open;
  }

  /// The cards in [conversation] that show a version of [card]'s node, [card]
  /// among them: every card a press on it may change. None when [card] was
  /// not sent to [conversation].
  List<String> cardsLike(String card, {required String conversation}) {
    final shown = _showing[card];
    if (shown == null || shown.conversation != conversation) return const [];
    return [
      for (final MapEntry(key: other, value: (conversation: sentTo, :target))
          in _showing.entries)
        if (sentTo == conversation &&
            sameVersion(target.exact, shown.target.exact))
          other,
    ];
  }

  /// What [bell] writes. Nothing, unless it is a press on a card this
  /// receiver shows, by an actor Teams named.
  Annotations read(JsonObject bell) {
    if (bell.string('event') != 'teams_card_action') return Annotations.none;
    final by = teamsActor(bell);
    if (by == null) {
      log('teams receiver: a press with no tenant or Entra user');
      return Annotations.none;
    }
    final card = bell.stringOrNull('reply_to');
    final shown = card == null ? null : _showing[card];
    if (shown == null) {
      log('teams receiver: a press on card $card, which shows no node');
      return Annotations.none;
    }
    if (shown.conversation != bell.stringOrNull('conversation')) {
      log('teams receiver: a press on card $card from another conversation');
      return Annotations.none;
    }
    final target = shown.target;
    final verb = bell
        .objectOrNull('value')
        ?.objectOrNull('action')
        ?.stringOrNull('verb');
    switch (verb) {
      case 'approve':
        return Annotations(
          approve: Approve(target: target, by: by),
        );
      case 'notyet':
        // The Seen is written even when nothing is withdrawn: when a pass
        // says something new, it is the only trace that he looked.
        return Annotations(
          seen: Seen(target: target, by: by),
          withdrawn: [
            for (final MapEntry(key: id, value: approval) in _standing.entries)
              if (approval.by == by &&
                  sameVersion(approval.target.exact, target.exact))
                Withdraw<Approve>(target: id, by: by),
          ],
        );
      case 'edit':
        // Edit reopens the choice on the card and writes nothing.
        return Annotations.none;
      default:
        log('teams receiver: a press with verb $verb');
        return Annotations.none;
    }
  }
}

/// Where one actor stands on one version of a node, as a card shows it.
enum Stance {
  /// Nothing of theirs is written of it: Approve and Not yet.
  open,

  /// An approval of theirs stands: Approved, and Edit.
  approved,

  /// They have seen it and no approval of theirs stands: Not yet noted, and
  /// Approve and Not yet.
  heldOff,
}

/// Who rang [bell]: `teams:<tenant>/<Entra object id>`, both GUIDs in lower
/// case. Null when Teams named no tenant or no Entra user, as for another
/// bot.
ActorId? teamsActor(JsonObject bell) {
  final tenant = bell.stringOrNull('tenant');
  final user = bell.stringOrNull('from_aad_object_id');
  if (tenant == null || user == null) return null;
  return ActorId.parse('teams:${tenant.toLowerCase()}/${user.toLowerCase()}');
}
