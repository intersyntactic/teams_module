/// Prints a renderer's id, read from `pubspec.lock` in the current
/// directory: the build a runner is compiled in. From that build's root:
///
///     dart compile exe -Drenderer=$(dart run render_runner:renderer_id \
///       <renderer package>) bin/<runner>.dart
///
/// Exits 1, printing why, unless the renderer is an archive on pub.dev.
library;

import 'dart:io';

import 'package:render_runner/renderer_id.dart';

void main(List<String> args) {
  if (args case [final package]) {
    final File lock = File('pubspec.lock');
    if (!lock.existsSync()) {
      stderr.writeln('renderer_id: no pubspec.lock here');
      exit(1);
    }
    switch (rendererIdFromLock(lock.readAsStringSync(), package)) {
      case (id: final String id, why: _):
        stdout.writeln(id);
      case (id: _, :final why):
        stderr.writeln('renderer_id: $why');
        exit(1);
    }
  } else {
    stderr.writeln('usage: renderer_id <renderer package>');
    exit(64);
  }
}
