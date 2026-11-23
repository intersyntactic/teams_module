/// Builds Teams app packages: for each bot, the zip an admin uploads,
/// holding the manifest and the two icons Teams requires.
///
///     dart run tool/app_package.dart [--version 1.2.3] [--settings-action]
///         APP_ID=NAME [APP_ID=NAME ...]
///
/// writes `build/appPackage/<app id>/` and `build/<name>.zip` for each, so
/// a pool of agent bots (researcher1, reviewer1, …) is one run. NAME is what
/// people see in Teams and @mention; the registration's own name is not.
/// `--settings-action` adds the message action that opens call settings
/// from a message's "..." menu, for the bot that coordinates. A trajectory
/// is closed from the menu on each of its replies' cards, not from here.
///
/// Manifest 1.21, not the newest: this app uses nothing newer than a bot in
/// personal and group-chat scopes, and an older version is the one an
/// upload validator that lags behind still accepts.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:is_teams_module/is_teams_module.dart';

const manifestVersion = '1.21';
// The icon's palette, worked out in OKLCH so that equal numbers look
// equally light: every pastel has the same lightness (0.87) and chroma
// (0.075) and differs only in hue, spread around the wheel and skipping the
// greens the background already holds. So no colour shouts over another.
const accent = (0x18, 0x47, 0x35); // forest green, behind it all
const _cream = (0xf5, 0xee, 0xe0); // the trajectories launched from it
const _butter = (0xeb, 0xd1, 0x9c); // the trajectory, hue 85

Future<void> main(List<String> args) async {
  const usage =
      'usage: dart run tool/app_package.dart [--version 1.2.3] '
      '[--settings-action] APP_ID=NAME [APP_ID=NAME ...]';
  // Teams takes a replacement package only if its version is higher than
  // the one already uploaded, so a re-upload names the next version.
  var version = '0.0.1';
  var settingsAction = false;
  final bots = <(BotAppId, String)>[];
  for (var i = 0; i < args.length; i++) {
    // wire-ok: command-line flags, read once here.
    switch (args[i]) {
      case '--version' when i + 1 < args.length:
        version = args[++i];
      case '--settings-action':
        settingsAction = true;
      case final pair:
        final eq = pair.indexOf('=');
        final id = eq < 0 ? null : BotAppId.parse(pair.substring(0, eq));
        if (id == null) {
          stderr.writeln(
            'abort: "$pair" is not APP_ID=NAME with a GUID\n$usage',
          );
          exit(64);
        }
        final name = pair.substring(eq + 1);
        if (name.isEmpty || name.length > 30) {
          stderr.writeln('abort: "$name": a short name is 1 to 30 characters');
          exit(64);
        }
        bots.add((id, name));
    }
  }
  if (bots.isEmpty) {
    stderr.writeln(usage);
    exit(64);
  }
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
    stderr.writeln('abort: "$version" is not a version like 1.2.3');
    exit(64);
  }
  final zipNames = {for (final (_, name) in bots) _fileName(name)};
  if (zipNames.length != bots.length) {
    stderr.writeln('abort: two names make the same file name');
    exit(64);
  }

  final colour = icon(192, outline: false);
  final outlined = icon(32, outline: true);
  for (final (appId, name) in bots) {
    final dir = Directory('build/appPackage/$appId')
      ..createSync(recursive: true);
    File('${dir.path}/manifest.json').writeAsStringSync(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(manifest(appId, name, version, settingsAction: settingsAction)),
    );
    File('${dir.path}/color.png').writeAsBytesSync(colour);
    File('${dir.path}/outline.png').writeAsBytesSync(outlined);

    final zip = File('build/${_fileName(name)}.zip');
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
      stderr.writeln('abort: zip failed for "$name": ${r.stderr}');
      exit(1);
    }
    stdout.writeln('wrote ${zip.path} for "$name" ($appId)');
  }
}

/// [name] as a file name: lower case, anything but letters and digits a
/// hyphen.
String _fileName(String name) =>
    name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-');

Map<String, Object?> manifest(
  BotAppId appId,
  String name,
  String version, {
  bool settingsAction = false,
}) => {
  r'$schema':
      'https://developer.microsoft.com/json-schemas/teams/'
      'v$manifestVersion/MicrosoftTeams.schema.json',
  'manifestVersion': manifestVersion,
  'version': version,
  'id': appId.value,
  'developer': {
    'name': 'Enspyr',
    'websiteUrl': 'https://enspyr.co',
    'privacyUrl': 'https://enspyr.co',
    'termsOfUseUrl': 'https://enspyr.co',
  },
  'name': {'short': name, 'full': name},
  'description': {
    'short': 'Take part in intersyntactic journeys from Teams.',
    'full':
        'Shows what a journey asks of you as a card. Approve it, say not '
        'yet, propose a correction, or comment, and the journey takes it in '
        'as a node on its path.',
  },
  'icons': {'color': 'color.png', 'outline': 'outline.png'},
  'accentColor':
      '#${[accent.$1, accent.$2, accent.$3].map((c) => c.toRadixString(16).padLeft(2, '0')).join()}',
  'bots': [
    {
      'botId': appId.value,
      'scopes': ['personal', 'groupChat'],
      'isNotificationOnly': false,
      'supportsFiles': false,
    },
  ],
  if (settingsAction)
    'composeExtensions': [
      {
        'botId': appId.value,
        'commands': [
          {
            'id': callSettingsCommandId,
            'type': 'action',
            'context': ['message'],
            'fetchTask': true,
            'title': 'Call settings',
            'description': 'Choose the model and effort the agent runs with',
          },
        ],
      },
    ],
  'validDomains': <String>[],
};

/// A trajectory drawn as a transit map. It runs in butter from its root up
/// to its tip, and from two of its nodes a new trajectory is launched in
/// cream: a new trajectory from a node, never a fork of the old.
/// Every node is a station coloured by who wrote it, people in rose and
/// periwinkle, agents in aqua and lavender, ringed in the background colour
/// so it stands clear of its line.
///
/// Points are in unit coordinates, on a transit map's right angles and
/// diagonals.
const _root = (0.28, 0.84);
const _trajectory = [_root, (0.28, 0.60), (0.50, 0.38), (0.50, 0.16)];
const _launchedTrajectories = [
  ((0.28, 0.60), (0.28, 0.16)), // straight up from the first node
  ((0.50, 0.38), (0.72, 0.16)), // up and right from the second
];

/// Who wrote each node, in [_trajectory] order after the root, then each
/// launched trajectory's tip in [_launchedTrajectories] order: a
/// trajectory's tip is the agent whose trajectory it is.
const _trajectoryActors = [_rose, _periwinkle, _aqua];
const _launchedTrajectoryActors = [_lavender, _lavender];
const _rose = (0xff, 0xc1, 0xc4); // a person, hue 15: green's complement
const _periwinkle = (0xbc, 0xd4, 0xff); // another person, hue 265
const _aqua = (0x98, 0xe4, 0xe8); // an agent, hue 200
const _lavender = (0xe7, 0xc6, 0xf7); // another agent, hue 315

typedef _Point = (double, double);
typedef _Stroke = (_Point, _Point);
typedef _Rgb = (int, int, int);

/// The transit map on forest green for the colour icon; white on transparent
/// for the outline icon, as Teams requires of each.
Uint8List icon(int size, {required bool outline}) {
  // The trajectory, root to tip, and the trajectories launched from it.
  final trajectory = <_Stroke>[
    for (var i = 0; i < _trajectory.length - 1; i++)
      (_trajectory[i], _trajectory[i + 1]),
  ];
  const launchedTrajectories = _launchedTrajectories;

  // At 32 pixels a thin stroke vanishes, so the outline icon draws heavier,
  // with nodes only a little wider than the strokes. In colour the trajectory
  // is heavier than those launched from it: it first, they second, stations
  // third.
  final trajectoryHalf = (outline ? 0.085 : 0.064) * size / 2;
  final launchedTrajectoryHalf = (outline ? 0.085 : 0.042) * size / 2;
  final dot = (outline ? 0.06 : 0.045) * size;
  final ring = outline ? 0.0 : 0.016 * size;
  final stations = <(_Point, _Rgb, double)>[
    (_root, _butter, dot * 1.25),
    for (var i = 1; i < _trajectory.length; i++)
      (_trajectory[i], _trajectoryActors[i - 1], dot),
    for (var i = 0; i < _launchedTrajectories.length; i++)
      (_launchedTrajectories[i].$2, _launchedTrajectoryActors[i], dot),
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
        var ink = max(
          inked(trajectory, trajectoryHalf),
          inked(launchedTrajectories, launchedTrajectoryHalf),
        );
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
      c = over(c, _cream, inked(launchedTrajectories, launchedTrajectoryHalf));
      c = over(c, _butter, inked(trajectory, trajectoryHalf));
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
