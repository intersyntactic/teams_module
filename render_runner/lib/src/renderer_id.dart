/// A renderer's id, read from the `pubspec.lock` of the build it is
/// compiled into.
///
/// A renderer is a package published on pub.dev, and its id is the sha256
/// of that version's archive: what pub records in the lockfile, and what
/// pub.dev reports as `archive_sha256`. So the id is read, never computed,
/// and anyone checks it with `curl` and `shasum -a 256`. A renderer reached
/// any other way (a path, a git ref, another server) has no archive anyone
/// else can fetch, so it has no id.
library;

import 'package:yaml/yaml.dart';

/// [package]'s id from the lockfile text [lock], or why there is none.
({String? id, String? why}) rendererIdFromLock(String lock, String package) {
  final Object? entry;
  try {
    entry = switch (loadYaml(lock)) {
      {'packages': final YamlMap packages} => packages[package],
      _ => null,
    };
  } on YamlException catch (e) {
    return (id: null, why: 'not a lockfile: ${e.message}');
  }
  return switch (entry) {
    null => (id: null, why: '$package is not in the lockfile'),
    {
      'source': 'hosted',
      'description': {'url': 'https://pub.dev', 'sha256': final String sha},
    }
        when _sha256.hasMatch(sha) =>
      (id: sha, why: null),
    {'source': 'hosted', 'description': {'url': 'https://pub.dev'}} => (
      id: null,
      why: '$package has no archive sha256 in the lockfile',
    ),
    {'source': final String source} => (
      id: null,
      why: '$package comes from $source, not an archive on pub.dev',
    ),
    _ => (id: null, why: '$package has no source in the lockfile'),
  };
}

final _sha256 = RegExp(r'^[0-9a-f]{64}$');
