/// Builds the Teams app package: the zip an admin uploads, holding the
/// manifest and the two icons Teams requires.
///
///     dart run tool/app_package.dart BOT_APP_ID [DISPLAY_NAME]
///
/// writes `build/appPackage/` and `build/appPackage.zip`. The display name
/// is what people see in Teams; the registration's own name is not.
///
/// Manifest 1.21, not the newest: this app uses nothing newer than a bot in
/// personal and group-chat scopes, and an older version is the one an
/// upload validator that lags behind still accepts.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const manifestVersion = '1.21';
// The icon's palette, worked out in OKLCH so that equal numbers look
// equally light: every pastel has the same lightness (0.87) and chroma
// (0.075) and differs only in hue, spread around the wheel and skipping the
// greens the background already holds. So no colour shouts over another.
const accent = (0x18, 0x47, 0x35); // forest green, behind it all
const _cream = (0xf5, 0xee, 0xe0); // the branches
const _butter = (0xeb, 0xd1, 0x9c); // the journey path, hue 85

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 3) {
    stderr.writeln(
      'usage: dart run tool/app_package.dart BOT_APP_ID [NAME] [VERSION]',
    );
    exit(64);
  }
  final appId = args[0].toLowerCase();
  if (!RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      .hasMatch(appId)) {
    stderr.writeln('abort: "$appId" is not a GUID');
    exit(64);
  }
  final name = args.length >= 2 ? args[1] : 'Hart Reports';
  if (name.isEmpty || name.length > 30) {
    stderr.writeln('abort: a short name is 1 to 30 characters');
    exit(64);
  }
  // Teams takes a replacement package only if its version is higher than
  // the one already uploaded, so a re-upload names the next version.
  final version = args.length == 3 ? args[2] : '0.0.1';
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
    stderr.writeln('abort: "$version" is not a version like 1.2.3');
    exit(64);
  }

  final dir = Directory('build/appPackage')..createSync(recursive: true);
  File('${dir.path}/manifest.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(manifest(appId, name, version)),
  );
  File('${dir.path}/color.png').writeAsBytesSync(icon(192, outline: false));
  File('${dir.path}/outline.png').writeAsBytesSync(icon(32, outline: true));

  final zip = File('build/appPackage.zip');
  if (zip.existsSync()) zip.deleteSync();
  // -j: the three files sit at the zip's root, where Teams looks for them.
  final r = await Process.run('zip', [
    '-j',
    '-X',
    zip.path,
    '${dir.path}/manifest.json',
    '${dir.path}/color.png',
    '${dir.path}/outline.png',
  ]);
  if (r.exitCode != 0) {
    stderr.writeln('abort: zip failed: ${r.stderr}');
    exit(1);
  }
  stdout.writeln('wrote ${zip.path} for "$name" ($appId)');
}

Map<String, Object?> manifest(String appId, String name, String version) => {
  r'$schema':
      'https://developer.microsoft.com/json-schemas/teams/'
      'v$manifestVersion/MicrosoftTeams.schema.json',
  'manifestVersion': manifestVersion,
  'version': version,
  'id': appId,
  'developer': {
    'name': 'Enspyr',
    'websiteUrl': 'https://enspyr.co',
    'privacyUrl': 'https://enspyr.co',
    'termsOfUseUrl': 'https://enspyr.co',
  },
  'name': {'short': name, 'full': name},
  'description': {
    'short': 'Review, correct and approve report drafts from Teams.',
    'full':
        'Shows each part of a report draft as a card. Approve it, say not '
        'yet, propose a correction, or comment, and the report takes it in '
        'on its next pass.',
  },
  'icons': {'color': 'color.png', 'outline': 'outline.png'},
  'accentColor':
      '#${[accent.$1, accent.$2, accent.$3].map((c) => c.toRadixString(16).padLeft(2, '0')).join()}',
  'bots': [
    {
      'botId': appId,
      'scopes': ['personal', 'groupChat'],
      'isNotificationOnly': false,
      'supportsFiles': false,
    },
  ],
  'validDomains': <String>[],
};

/// A hart's antlers drawn as a tree of nodes: a root at the base, branches
/// forking upward, a node at every tine's tip. Hart is a stag, and what the
/// module feeds is a tree of nodes on journey paths, so the one shape is
/// both.
///
/// The colour icon reads like a transit map. A journey path runs in butter
/// from the root up each beam to its top tip; the tines branch off it in
/// cream. Every node is a station coloured by who wrote it, people in rose
/// and periwinkle, agents in aqua and lavender, ringed in the background
/// colour so it stands clear of its line. Left and right mirror each other,
/// colours too.
///
/// The left antler is given in unit coordinates and mirrored for the right.
const _beam = [(0.42, 0.70), (0.33, 0.52), (0.27, 0.34), (0.25, 0.17)];
const _tines = [
  ((0.37, 0.61), (0.17, 0.57)), // brow tine, out
  ((0.30, 0.43), (0.13, 0.33)), // middle tine, out and up
  ((0.27, 0.33), (0.39, 0.20)), // inner tine, in and up
];
const _root = (0.5, 0.84);

/// Who wrote each tine's tip, in [_tines] order, mirrored on the right; the
/// path's top tips are the agent whose path it is.
const _tineActors = [_rose, _periwinkle, _lavender];
const _pathActor = _aqua;
const _rose = (0xff, 0xc1, 0xc4); // a person, hue 15: green's complement
const _periwinkle = (0xbc, 0xd4, 0xff); // another person, hue 265
const _aqua = (0x98, 0xe4, 0xe8); // an agent, hue 200
const _lavender = (0xe7, 0xc6, 0xf7); // another agent, hue 315

typedef _Point = (double, double);
typedef _Stroke = (_Point, _Point);
typedef _Rgb = (int, int, int);

/// Transit-map antlers on forest green for the colour icon; white on
/// transparent for the outline icon, as Teams requires of each.
Uint8List icon(int size, {required bool outline}) {
  _Point mirror(_Point p) => (1 - p.$1, p.$2);
  List<_Stroke> both(List<_Stroke> s) => [
    ...s,
    for (final (a, b) in s) (mirror(a), mirror(b)),
  ];
  // At 32 pixels three tines a side crowd into a blob, so the outline icon
  // keeps only the brow and inner tines.
  final tines = outline ? [_tines.first, _tines.last] : _tines;
  final actors = outline ? [_tineActors.first, _tineActors.last] : _tineActors;

  // The journey path, root to each top tip, and the tines branching off it.
  final path = both([
    (_root, _beam.first),
    for (var i = 0; i < _beam.length - 1; i++) (_beam[i], _beam[i + 1]),
  ]);
  final branches = both(tines);

  // At 32 pixels a thin stroke vanishes, so the outline icon draws heavier,
  // with nodes only a little wider than the strokes. In colour the path is
  // heavier than its branches: path first, branches second, stations third.
  final pathHalf = (outline ? 0.085 : 0.064) * size / 2;
  final branchHalf = (outline ? 0.085 : 0.042) * size / 2;
  final dot = (outline ? 0.06 : 0.045) * size;
  final ring = outline ? 0.0 : 0.016 * size;
  final stations = <(_Point, _Rgb, double)>[
    (_root, _butter, dot * 1.25),
    (_beam.last, _pathActor, dot),
    (mirror(_beam.last), _pathActor, dot),
    for (var i = 0; i < tines.length; i++) ...[
      (tines[i].$2, actors[i], dot),
      (mirror(tines[i].$2), actors[i], dot),
    ],
  ];

  final rgba = Uint8List(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final px = x + 0.5, py = y + 0.5;
      double from(_Point p) =>
          sqrt(pow(p.$1 * size - px, 2) + pow(p.$2 * size - py, 2));
      // One pixel of soft edge everywhere, so nothing is jagged.
      double within(double r, double d) => (r + 0.5 - d).clamp(0.0, 1.0);
      double inked(List<_Stroke> strokes, double half) {
        var d = double.infinity;
        for (final (a, b) in strokes) {
          d = min(
            d,
            _toSegment(
              px,
              py,
              a.$1 * size,
              a.$2 * size,
              b.$1 * size,
              b.$2 * size,
            ),
          );
        }
        return within(half, d);
      }

      final o = (y * size + x) * 4;
      if (outline) {
        var ink = max(inked(path, pathHalf), inked(branches, branchHalf));
        for (final (at, _, r) in stations) {
          ink = max(ink, within(r, from(at)));
        }
        rgba.setAll(o, [255, 255, 255, (ink * 255).round()]);
        continue;
      }
      var c = accent;
      _Rgb over(_Rgb under, _Rgb top, double a) => (
        (under.$1 + (top.$1 - under.$1) * a).round(),
        (under.$2 + (top.$2 - under.$2) * a).round(),
        (under.$3 + (top.$3 - under.$3) * a).round(),
      );
      c = over(c, _cream, inked(branches, branchHalf));
      c = over(c, _butter, inked(path, pathHalf));
      for (final (at, colour, r) in stations) {
        final d = from(at);
        c = over(c, accent, within(r + ring, d));
        c = over(c, colour, within(r, d));
      }
      rgba.setAll(o, [c.$1, c.$2, c.$3, 255]);
    }
  }
  return _png(size, rgba);
}

double _toSegment(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final dx = bx - ax, dy = by - ay;
  final t = (((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)).clamp(
    0.0,
    1.0,
  );
  final cx = ax + t * dx - px, cy = ay + t * dy - py;
  return sqrt(cx * cx + cy * cy);
}

/// An 8-bit RGBA PNG: signature, IHDR, one IDAT, IEND.
Uint8List _png(int size, Uint8List rgba) {
  final raw = BytesBuilder();
  for (var y = 0; y < size; y++) {
    raw.addByte(0); // filter: none
    raw.add(rgba.sublist(y * size * 4, (y + 1) * size * 4));
  }
  final out = BytesBuilder()
    ..add([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  void chunk(String type, List<int> data) {
    final typed = [...ascii.encode(type), ...data];
    out
      ..add(_u32(data.length))
      ..add(typed)
      ..add(_u32(_crc32(typed)));
  }

  chunk('IHDR', [..._u32(size), ..._u32(size), 8, 6, 0, 0, 0]);
  chunk('IDAT', ZLibEncoder().convert(raw.takeBytes()));
  chunk('IEND', const []);
  return out.takeBytes();
}

List<int> _u32(int v) => [
  v >> 24 & 0xff,
  v >> 16 & 0xff,
  v >> 8 & 0xff,
  v & 0xff,
];

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 == 1 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xffffffff;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}
