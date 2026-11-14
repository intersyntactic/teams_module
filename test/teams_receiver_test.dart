import 'dart:convert';

import 'package:checked_json/checked_json.dart';
import 'package:is_annotation_shapes/is_annotation_shapes.dart';
import 'package:is_shapes/is_shapes.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

/// An example's wording, the value a later pass may change.
final class Wording extends Value {
  const Wording(this.text);
  final String text;
}

/// A node a card shows, as a module's nodes are.
final class Example {
  const Example(this.key, this.wording);
  @identity
  final String key;
  final Wording wording;
}

const tenant = '09e0393f-03f1-4206-84f3-8b127b750a5d';
const ada = 'aaaaaaaa-0000-4000-8000-000000000001';
const bea = 'bbbbbbbb-0000-4000-8000-000000000002';

/// Ada's one-to-one chat with the bot.
const chat = 'a:ada';

TeamsPressed press(
  String card,
  String? verb, {
  String? user = ada,
  String? tenantId = tenant,
  String conversation = chat,
}) => TeamsPressed(
  conversation: conversation,
  id: 'press-of-$card',
  serviceUrl: Uri.parse('https://smba.trafficmanager.net/amer/'),
  tenant: tenantId,
  fromAadObjectId: user,
  card: card,
  value: JsonObject.of({
    'action': {'verb': ?verb},
  }),
);

void main() {
  late StandInJourneyPath journeyPath;
  late TeamsReceiver receiver;
  late List<String> logged;
  late Map<Object, TurnId> ids;

  setUp(() {
    logged = [];
    ids = Map.identity();
    receiver = TeamsReceiver(
      sameVersion: (a, b) => journeyPath.sameVersion(a, b),
      log: logged.add,
    );
    journeyPath = StandInJourneyPath(
      deliver: (id, node) {
        ids[node] = id;
        receiver.delivered(id, node);
      },
      encodeOther: (node) => switch (node) {
        Example(:final key, :final wording) => {
          'shape': 'Example',
          'key': key,
          'wording': wording.text,
        },
        _ => throw ArgumentError.value(node, 'node', 'no encoding'),
      },
    );
  });

  ActorId actor(String user) => ActorId.parse('teams:$tenant/$user')!;

  /// Appends [example] as one pass would, and shows it on [card].
  Target shown(String card, Example example, {String conversation = chat}) {
    final target = Target(
      exact: journeyPath.append(example),
      anchor: SemanticAnchor.of(utf8.encode(example.key)),
    );
    receiver.show(card, target, conversation: conversation);
    return target;
  }

  /// Reads [event] and appends what it writes, as the module does.
  Annotations write(TeamsEvent event) {
    final written = receiver.read(event);
    written.inOrder.forEach(journeyPath.append);
    return written;
  }

  const planned = Example('example-3', Wording('as planned'));

  test('Approve on a shown card writes an Approve of its node', () {
    final target = shown('card-1', planned);
    final written = write(press('card-1', 'approve'));
    expect(written.inOrder, hasLength(1));
    expect(written.approve!.target, target);
    expect(written.approve!.by, actor(ada));
  });

  test('the actor id is lower case, whatever case Teams sends', () {
    shown('card-1', planned);
    final written = write(
      press(
        'card-1',
        'approve',
        user: ada.toUpperCase(),
        tenantId: tenant.toUpperCase(),
      ),
    );
    expect('${written.approve!.by}', 'teams:$tenant/$ada');
  });

  test('a press on a card that shows no node writes nothing', () {
    shown('card-1', planned);
    expect(write(press('card-2', 'approve')).inOrder, isEmpty);
    expect(logged.single, contains('card-2'));
  });

  test('a press from another conversation than the card was sent to '
      'writes nothing', () {
    shown('card-1', planned);
    expect(
      write(press('card-1', 'approve', conversation: 'a:other')).inOrder,
      isEmpty,
    );
    expect(logged.single, contains('another conversation'));
  });

  test('a press with no Entra user or no tenant writes nothing', () {
    shown('card-1', planned);
    expect(write(press('card-1', 'approve', user: null)).inOrder, isEmpty);
    expect(write(press('card-1', 'approve', tenantId: null)).inOrder, isEmpty);
    expect(logged, hasLength(2));
  });

  test('Edit, an unknown verb, and anything but a press write nothing', () {
    shown('card-1', planned);
    write(press('card-1', 'approve'));
    expect(write(press('card-1', 'edit')).inOrder, isEmpty);
    expect(write(press('card-1', 'shrug')).inOrder, isEmpty);
    expect(write(press('card-1', null)).inOrder, isEmpty);
    final message = TeamsSaid(
      conversation: chat,
      id: 'act-1',
      serviceUrl: Uri.parse('https://smba.trafficmanager.net/amer/'),
      tenant: tenant,
      fromAadObjectId: ada,
      text: 'hi',
    );
    expect(write(message).inOrder, isEmpty);
  });

  test('Not yet with nothing approved writes only a Seen', () {
    final target = shown('card-1', planned);
    final written = write(press('card-1', 'notyet'));
    expect(written.inOrder, hasLength(1));
    expect(written.seen!.target, target);
    expect(written.seen!.by, actor(ada));
  });

  test('Not yet withdraws every standing approval of his of that version, '
      'on any pass', () {
    shown('card-1', planned);
    final first = write(press('card-1', 'approve'));
    final second = write(press('card-1', 'approve'));
    // A later pass: a new exact id, saying the same.
    final later = shown('card-2', planned);
    final third = write(press('card-2', 'approve'));
    final written = write(press('card-2', 'notyet'));

    expect(written.seen!.target, later);
    expect(written.inOrder.first, isA<Seen>());
    expect(written.withdrawn.map((w) => w.by).toSet(), {actor(ada)});
    expect(
      written.withdrawn.map((w) => w.target),
      unorderedEquals([first, second, third].map((w) => ids[w.approve]!)),
    );
  });

  test('Not yet leaves his approvals of what an earlier pass said', () {
    shown('card-1', planned);
    write(press('card-1', 'approve'));
    shown('card-2', const Example('example-3', Wording('done')));
    final written = write(press('card-2', 'notyet'));
    expect(written.seen, isNotNull);
    expect(written.withdrawn, isEmpty);
  });

  test("Not yet leaves someone else's approvals", () {
    shown('card-1', planned);
    write(press('card-1', 'approve', user: bea));
    expect(write(press('card-1', 'notyet')).withdrawn, isEmpty);
  });

  test('a withdrawn approval is not withdrawn again', () {
    shown('card-1', planned);
    write(press('card-1', 'approve'));
    expect(write(press('card-1', 'notyet')).withdrawn, hasLength(1));
    expect(write(press('card-1', 'notyet')).withdrawn, isEmpty);
  });

  test('Approve, Not yet, Approve leaves one standing approval', () {
    shown('card-1', planned);
    write(press('card-1', 'approve'));
    write(press('card-1', 'notyet'));
    write(press('card-1', 'approve'));
    expect(write(press('card-1', 'notyet')).withdrawn, hasLength(1));
  });

  test("a withdrawal by anyone but the author doesn't take it back", () {
    shown('card-1', planned);
    final approval = ids[write(press('card-1', 'approve')).approve]!;
    // Bea names Ada's approval: it counts for nothing.
    journeyPath.append(Withdraw<Approve>(target: approval, by: actor(bea)));
    expect(write(press('card-1', 'notyet')).withdrawn.map((w) => w.target), [
      approval,
    ]);
  });

  group('where he stands', () {
    test('is open on a version nothing of his is written of', () {
      final target = shown('card-1', planned);
      write(press('card-1', 'approve', user: bea));
      expect(receiver.stanceOf(actor(ada), target.exact), Stance.open);
    });

    test('is approved on a later pass that says the same', () {
      shown('card-1', planned);
      write(press('card-1', 'approve'));
      final later = shown('card-2', planned);
      expect(receiver.stanceOf(actor(ada), later.exact), Stance.approved);
    });

    test('is open on a later pass that says something new', () {
      shown('card-1', planned);
      write(press('card-1', 'approve'));
      final done = shown('card-2', const Example('example-3', Wording('done')));
      expect(receiver.stanceOf(actor(ada), done.exact), Stance.open);
    });

    test('is held off on every pass after Not yet on any one', () {
      final first = shown('card-1', planned);
      write(press('card-1', 'approve'));
      shown('card-2', planned);
      write(press('card-2', 'notyet'));
      expect(receiver.stanceOf(actor(ada), first.exact), Stance.heldOff);
    });

    test('is approved again after Approve on a held-off version', () {
      final first = shown('card-1', planned);
      write(press('card-1', 'notyet'));
      write(press('card-1', 'approve'));
      expect(receiver.stanceOf(actor(ada), first.exact), Stance.approved);
    });
  });

  group('the cards a press may change', () {
    test('are the cards in its conversation showing the same version', () {
      shown('card-1', planned);
      shown('card-2', const Example('example-3', Wording('done')));
      shown('card-3', planned);
      shown('card-4', planned, conversation: 'a:bea');
      expect(
        receiver.cardsLike('card-3', conversation: chat),
        unorderedEquals(['card-1', 'card-3']),
      );
    });

    test('are none for a card it was never shown', () {
      shown('card-1', planned);
      expect(receiver.cardsLike('card-9', conversation: chat), isEmpty);
    });

    test('are none for a press from another conversation', () {
      shown('card-1', planned);
      expect(receiver.cardsLike('card-1', conversation: 'a:other'), isEmpty);
    });
  });

  group('the stand-in journey path', () {
    test('names the same bytes on two passes differently, as one version', () {
      final a = journeyPath.append(planned);
      final b = journeyPath.append(planned);
      expect(a, isNot(b));
      expect(journeyPath.sameVersion(a, b), isTrue);
    });

    test('tells apart two nodes that say different things', () {
      final a = journeyPath.append(planned);
      final b = journeyPath.append(const Example('example-3', Wording('done')));
      expect(journeyPath.sameVersion(a, b), isFalse);
    });

    test('knows no version of a node it never appended', () {
      final a = journeyPath.append(planned);
      final stranger = TurnId.of(utf8.encode('elsewhere'));
      expect(journeyPath.sameVersion(stranger, stranger), isFalse);
      expect(journeyPath.sameVersion(a, stranger), isFalse);
    });
  });
}
