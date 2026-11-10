import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:is_annotation_shapes/is_annotation_shapes.dart';
import 'package:is_shapes/is_shapes.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

/// A rung's verdict, the value a later pass may change.
final class Verdict extends Value {
  const Verdict(this.level);
  final String level;
}

/// A node a card shows, as Hart's rungs are.
final class Rung {
  const Rung(this.failureMode, this.verdict);
  @identity
  final String failureMode;
  final Verdict verdict;
}

const tenant = '09e0393f-03f1-4206-84f3-8b127b750a5d';
const peter = 'aaaaaaaa-0000-4000-8000-000000000001';
const sian = 'bbbbbbbb-0000-4000-8000-000000000002';

/// Peter's one-to-one chat with the bot.
const chat = 'a:peter';

JsonObject press(
  String card,
  String? verb, {
  String? user = peter,
  String? tenantId = tenant,
  String conversation = chat,
}) => JsonObject.of({
  'event': 'teams_card_action',
  'tenant': ?tenantId,
  'conversation': conversation,
  'reply_to': card,
  'from_aad_object_id': ?user,
  'value': {
    'action': {'verb': ?verb},
  },
});

void main() {
  late StandInLine line;
  late TeamsReceiver receiver;
  late List<String> logged;
  late Map<Object, TurnId> ids;

  setUp(() {
    logged = [];
    ids = Map.identity();
    receiver = TeamsReceiver(
      sameVersion: (a, b) => line.sameVersion(a, b),
      log: logged.add,
    );
    line = StandInLine(
      deliver: (id, node) {
        ids[node] = id;
        receiver.delivered(id, node);
      },
      encodeOther: (node) => switch (node) {
        Rung(:final failureMode, :final verdict) => {
          'shape': 'Rung',
          'failureMode': failureMode,
          'level': verdict.level,
        },
        _ => throw ArgumentError.value(node, 'node', 'no encoding'),
      },
    );
  });

  ActorId actor(String user) => ActorId.parse('teams:$tenant/$user')!;

  /// Appends [rung] as one pass would, and shows it on [card].
  Target shown(String card, Rung rung, {String conversation = chat}) {
    final target = Target(
      exact: line.append(rung),
      anchor: SemanticAnchor.of(utf8.encode(rung.failureMode)),
    );
    receiver.show(card, target, conversation: conversation);
    return target;
  }

  /// Reads [bell] and appends what it writes, as the module does.
  Annotations write(JsonObject bell) {
    final written = receiver.read(bell);
    written.inOrder.forEach(line.append);
    return written;
  }

  const supported = Rung('rung-3', Verdict('supported'));

  test('Approve on a shown card writes an Approve of its node', () {
    final target = shown('card-1', supported);
    final written = write(press('card-1', 'approve'));
    expect(written.inOrder, hasLength(1));
    expect(written.approve!.target, target);
    expect(written.approve!.by, actor(peter));
  });

  test('the actor id is lower case, whatever case Teams sends', () {
    shown('card-1', supported);
    final written = write(
      press(
        'card-1',
        'approve',
        user: peter.toUpperCase(),
        tenantId: tenant.toUpperCase(),
      ),
    );
    expect('${written.approve!.by}', 'teams:$tenant/$peter');
  });

  test('a press on a card that shows no node writes nothing', () {
    shown('card-1', supported);
    expect(write(press('card-2', 'approve')).inOrder, isEmpty);
    expect(logged.single, contains('card-2'));
  });

  test('a press from another conversation than the card was sent to '
      'writes nothing', () {
    shown('card-1', supported);
    expect(
      write(press('card-1', 'approve', conversation: 'a:other')).inOrder,
      isEmpty,
    );
    expect(logged.single, contains('another conversation'));
  });

  test('a press with no Entra user or no tenant writes nothing', () {
    shown('card-1', supported);
    expect(write(press('card-1', 'approve', user: null)).inOrder, isEmpty);
    expect(write(press('card-1', 'approve', tenantId: null)).inOrder, isEmpty);
    expect(logged, hasLength(2));
  });

  test('Edit, an unknown verb, and anything but a press write nothing', () {
    shown('card-1', supported);
    write(press('card-1', 'approve'));
    expect(write(press('card-1', 'edit')).inOrder, isEmpty);
    expect(write(press('card-1', 'shrug')).inOrder, isEmpty);
    expect(write(press('card-1', null)).inOrder, isEmpty);
    final message = JsonObject.of({'event': 'teams_message', 'text': 'hi'});
    expect(write(message).inOrder, isEmpty);
  });

  test('Not yet with nothing approved writes only a Seen', () {
    final target = shown('card-1', supported);
    final written = write(press('card-1', 'notyet'));
    expect(written.inOrder, hasLength(1));
    expect(written.seen!.target, target);
    expect(written.seen!.by, actor(peter));
  });

  test('Not yet withdraws every standing approval of his of that version, '
      'on any pass', () {
    shown('card-1', supported);
    final first = write(press('card-1', 'approve'));
    final second = write(press('card-1', 'approve'));
    // A later pass: a new exact id, saying the same.
    final later = shown('card-2', supported);
    final third = write(press('card-2', 'approve'));
    final written = write(press('card-2', 'notyet'));

    expect(written.seen!.target, later);
    expect(written.inOrder.first, isA<Seen>());
    expect(written.withdrawn.map((w) => w.by).toSet(), {actor(peter)});
    expect(
      written.withdrawn.map((w) => w.target),
      unorderedEquals([first, second, third].map((w) => ids[w.approve]!)),
    );
  });

  test('Not yet leaves his approvals of what an earlier pass said', () {
    shown('card-1', supported);
    write(press('card-1', 'approve'));
    shown('card-2', const Rung('rung-3', Verdict('weak')));
    final written = write(press('card-2', 'notyet'));
    expect(written.seen, isNotNull);
    expect(written.withdrawn, isEmpty);
  });

  test("Not yet leaves someone else's approvals", () {
    shown('card-1', supported);
    write(press('card-1', 'approve', user: sian));
    expect(write(press('card-1', 'notyet')).withdrawn, isEmpty);
  });

  test('a withdrawn approval is not withdrawn again', () {
    shown('card-1', supported);
    write(press('card-1', 'approve'));
    expect(write(press('card-1', 'notyet')).withdrawn, hasLength(1));
    expect(write(press('card-1', 'notyet')).withdrawn, isEmpty);
  });

  test('Approve, Not yet, Approve leaves one standing approval', () {
    shown('card-1', supported);
    write(press('card-1', 'approve'));
    write(press('card-1', 'notyet'));
    write(press('card-1', 'approve'));
    expect(write(press('card-1', 'notyet')).withdrawn, hasLength(1));
  });

  test("a withdrawal by anyone but the author doesn't take it back", () {
    shown('card-1', supported);
    final approval = ids[write(press('card-1', 'approve')).approve]!;
    // Sian names Peter's approval: it counts for nothing.
    line.append(Withdraw<Approve>(target: approval, by: actor(sian)));
    expect(write(press('card-1', 'notyet')).withdrawn.map((w) => w.target), [
      approval,
    ]);
  });

  group('where he stands', () {
    test('is open on a version nothing of his is written of', () {
      final target = shown('card-1', supported);
      write(press('card-1', 'approve', user: sian));
      expect(receiver.stanceOf(actor(peter), target.exact), Stance.open);
    });

    test('is approved on a later pass that says the same', () {
      shown('card-1', supported);
      write(press('card-1', 'approve'));
      final later = shown('card-2', supported);
      expect(receiver.stanceOf(actor(peter), later.exact), Stance.approved);
    });

    test('is open on a later pass that says something new', () {
      shown('card-1', supported);
      write(press('card-1', 'approve'));
      final weak = shown('card-2', const Rung('rung-3', Verdict('weak')));
      expect(receiver.stanceOf(actor(peter), weak.exact), Stance.open);
    });

    test('is held off on every pass after Not yet on any one', () {
      final first = shown('card-1', supported);
      write(press('card-1', 'approve'));
      shown('card-2', supported);
      write(press('card-2', 'notyet'));
      expect(receiver.stanceOf(actor(peter), first.exact), Stance.heldOff);
    });

    test('is approved again after Approve on a held-off version', () {
      final first = shown('card-1', supported);
      write(press('card-1', 'notyet'));
      write(press('card-1', 'approve'));
      expect(receiver.stanceOf(actor(peter), first.exact), Stance.approved);
    });
  });

  group('the cards a press may change', () {
    test('are the cards in its conversation showing the same version', () {
      shown('card-1', supported);
      shown('card-2', const Rung('rung-3', Verdict('weak')));
      shown('card-3', supported);
      shown('card-4', supported, conversation: 'a:sian');
      expect(
        receiver.cardsLike('card-3', conversation: chat),
        unorderedEquals(['card-1', 'card-3']),
      );
    });

    test('are none for a card it was never shown', () {
      shown('card-1', supported);
      expect(receiver.cardsLike('card-9', conversation: chat), isEmpty);
    });

    test('are none for a press from another conversation', () {
      shown('card-1', supported);
      expect(receiver.cardsLike('card-1', conversation: 'a:other'), isEmpty);
    });
  });

  group('the stand-in line', () {
    test('names the same bytes on two passes differently, as one version', () {
      final a = line.append(supported);
      final b = line.append(supported);
      expect(a, isNot(b));
      expect(line.sameVersion(a, b), isTrue);
    });

    test('tells apart two nodes that say different things', () {
      final a = line.append(supported);
      final b = line.append(const Rung('rung-3', Verdict('weak')));
      expect(line.sameVersion(a, b), isFalse);
    });

    test('knows no version of a node it never appended', () {
      final a = line.append(supported);
      final stranger = TurnId.of(utf8.encode('elsewhere'));
      expect(line.sameVersion(stranger, stranger), isFalse);
      expect(line.sameVersion(a, stranger), isFalse);
    });
  });
}
