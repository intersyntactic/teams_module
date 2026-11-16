import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:test/test.dart';

/// The SDK half of import admission's pure list
/// (https://github.com/enspyrco/intersyntactic/issues/1046). The package
/// half is left out on purpose: the renderer's id hashes only this
/// package's `lib/`, so a package import would let code the id cannot see
/// change what is drawn.
const _pureSdk = {
  'dart:async',
  'dart:collection',
  'dart:convert',
  'dart:core',
  'dart:math',
  'dart:typed_data',
};

/// Every URI a source's directives name, in every branch, as written, read
/// from the parse tree as shapes' `test/pure_list_test.dart` reads them, so
/// a conditional import's other branches are seen too.
Iterable<StringLiteral> _directiveUris(String source) sync* {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  for (final directive in unit.directives) {
    yield* switch (directive) {
      NamespaceDirective(:final uri, :final configurations) => [
        uri,
        for (final branch in configurations) branch.uri,
      ],
      PartDirective(:final uri) => [uri],
      LibraryDirective() || PartOfDirective() => const <StringLiteral>[],
    };
  }
}

bool _isPure(StringLiteral literal) {
  final target = literal.stringValue;
  if (target == null) return false;
  final uri = Uri.parse(target);
  return switch (uri.scheme) {
    'dart' => _pureSdk.contains(target),
    '' => !uri.pathSegments.contains('..'),
    _ => false,
  };
}

void main() {
  test('lib imports only the pure SDK libraries, and no package', () {
    final violations = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File && file.path.endsWith('.dart'))
          for (final uri in _directiveUris(file.readAsStringSync()))
            if (!_isPure(uri)) '${file.path}: ${uri.toSource()}',
    ];
    expect(violations, isEmpty);
  });
}
