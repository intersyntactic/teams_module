import 'dart:convert';
import 'dart:typed_data';

import 'package:is_annotation_shapes/is_annotation_shapes.dart';
import 'package:is_shapes/is_shapes.dart';

/// A stand-in for a journey path, for running the module before it is
/// composed into a journey: it appends nodes in order, names each the way the
/// journey path does, by the sha256 of its parent's id and its own bytes, and
/// delivers each to [deliver] as it is appended.
///
/// Its bytes for a node are its own: the node's shape and fields as JSON, from
/// [encode] for the annotation shapes and [encodeOther] for any other. They
/// say what the node says and nothing more, so equal bytes are one version.
/// A real journey path hashes a small envelope of its own in with them, and
/// the parent's id, so an id minted here means nothing there.
final class StandInJourneyPath {
  StandInJourneyPath({required this.deliver, required this.encodeOther});

  /// Where each node goes once appended: to every acceptor of its shape.
  final void Function(TurnId id, Object node) deliver;

  /// The shape and fields of a node that is not an annotation shape.
  final Map<String, Object?> Function(Object node) encodeOther;

  final _says = <TurnId, String>{};
  TurnId? _head;

  /// Appends [node] after the head, delivers it, and returns its id.
  TurnId append(Object node) {
    final says = jsonEncode(encode(node) ?? encodeOther(node));
    final id = TurnId.of(
      Uint8List.fromList([...?_head?.bytes, ...utf8.encode(says)]),
    );
    _says[id] = says;
    _head = id;
    deliver(id, node);
    return id;
  }

  /// Whether the nodes at [a] and [b] say the same thing. False for a node
  /// this journey path never appended.
  bool sameVersion(TurnId a, TurnId b) =>
      _says.containsKey(a) && _says[a] == _says[b];

  /// The shape and fields of an annotation shape, or null for any other.
  static Map<String, Object?>? encode(Object node) => switch (node) {
    Approval(:final target, :final by) => {
      'shape': 'Approval',
      'target': _target(target),
      'by': '$by',
    },
    Seen(:final target, :final by) => {
      'shape': 'Seen',
      'target': _target(target),
      'by': '$by',
    },
    Withdrawal<Approval>(:final target, :final by) => {
      'shape': 'Withdrawal<Approval>',
      'target': '$target',
      'by': '$by',
    },
    _ => null,
  };

  static Map<String, Object?> _target(Target t) => {
    'exact': '${t.exact}',
    'anchor': '${t.anchor}',
  };
}
