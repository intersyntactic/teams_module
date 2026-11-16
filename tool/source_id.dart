/// Prints the define a teams-reply build needs to name its source:
///
///     dart compile exe $(dart run tool/source_id.dart) bin/teams_reply.dart
///
/// The source is every file the build reads, outside the Dart SDK, as the
/// compiler itself lists them (its depfile): so an import added later is in
/// the set without anyone remembering to add it. Each file is listed as
/// `./<package>/<path from the package's root>`, and the id is is_content_id's
/// FileSetId of that listing. With `--listing` it prints the listing
/// instead, which `shasum -a 256` turns into the same id:
///
///     dart run tool/source_id.dart --listing | shasum -a 256
///
/// The SDK is not in the set: which Dart compiled it is the build's to say.
library;

import 'dart:convert';
import 'dart:io';

import 'package:is_content_id/is_content_id.dart';

const _entry = 'bin/teams_reply.dart';

Future<void> main(List<String> args) async {
  final listing = args.contains('--listing');
  final dir = await Directory.systemTemp.createTemp('source_id');
  try {
    final depfile = '${dir.path}/deps';
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      '--depfile=$depfile',
      '-o',
      '${dir.path}/out.dill',
      _entry,
    ]);
    if (compiled.exitCode != 0) {
      _abort('the build does not compile:\n${compiled.stderr}');
    }
    final files = _files(File(depfile).readAsStringSync());
    final sdk = File(Platform.resolvedExecutable).parent.parent.path;
    final roots = _packageRoots();

    final ids = <ListedPath, ObjectId>{};
    for (final file in files) {
      if (file.startsWith('$sdk/') || file.endsWith('package_config.json')) {
        continue;
      }
      final listed = _listed(file, roots);
      if (listed == null) _abort('$file is in no package');
      ids[listed] = ObjectId.of(File(file).readAsBytesSync());
    }
    final id = FileSetId.of(ids);
    if (id == null) _abort('the build reads no files');
    if (listing) {
      final sorted = ids.keys.map((p) => p.toString()).toList()..sort();
      for (final p in sorted) {
        stdout.write('${ids[ListedPath.parse(p)]!.hex}  ./$p\n');
      }
    } else {
      stdout.writeln('-Dteams_reply.source=${id.hex}');
    }
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// The paths a Ninja depfile lists after its `<output>:`, with `\ ` read as
/// a space in a path.
List<String> _files(String depfile) {
  final after = depfile.substring(depfile.indexOf(': ') + 2).trim();
  return [
    for (final p in after.split(RegExp(r'(?<!\\) ')))
      if (p.isNotEmpty) p.replaceAll(r'\ ', ' '),
  ];
}

/// Each package's root directory, from `.dart_tool/package_config.json`.
Map<String, String> _packageRoots() {
  final config = File('.dart_tool/package_config.json');
  final json = jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
  return {
    for (final p in (json['packages']! as List).cast<Map<String, Object?>>())
      p['name']! as String: config.absolute.uri
          .resolve(p['rootUri']! as String)
          .toFilePath()
          .replaceAll(RegExp(r'/$'), ''),
  };
}

/// [file] as `<package>/<path from its root>`, by the deepest root holding
/// it; null if no package holds it.
ListedPath? _listed(String file, Map<String, String> roots) {
  String? best;
  for (final MapEntry(key: name, value: root) in roots.entries) {
    if (file.startsWith('$root/') &&
        (best == null || root.length > roots[best]!.length)) {
      best = name;
    }
  }
  if (best == null) return null;
  return ListedPath.parse('$best/${file.substring(roots[best]!.length + 1)}');
}

Never _abort(String why) {
  stderr.writeln('source_id: $why');
  exit(1);
}
