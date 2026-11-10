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
const accent = (0x2f, 0x6f, 0x6a); // a dark teal

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 2) {
    stderr.writeln('usage: dart run tool/app_package.dart BOT_APP_ID [NAME]');
    exit(64);
  }
  final appId = args[0].toLowerCase();
  if (!RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      .hasMatch(appId)) {
    stderr.writeln('abort: "$appId" is not a GUID');
    exit(64);
  }
  final name = args.length == 2 ? args[1] : 'Hart Reports';
  if (name.isEmpty || name.length > 30) {
    stderr.writeln('abort: a short name is 1 to 30 characters');
    exit(64);
  }

  final dir = Directory('build/appPackage')..createSync(recursive: true);
  File('${dir.path}/manifest.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(manifest(appId, name)),
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

Map<String, Object?> manifest(String appId, String name) => {
  r'$schema':
      'https://developer.microsoft.com/json-schemas/teams/'
      'v$manifestVersion/MicrosoftTeams.schema.json',
  'manifestVersion': manifestVersion,
  'version': '0.0.1',
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

/// A check mark: white on the accent colour for the colour icon, white on
/// transparent for the outline icon, as Teams requires of each.
Uint8List icon(int size, {required bool outline}) {
  const path = [(0.22, 0.53), (0.42, 0.72), (0.78, 0.31)];
  final half = (outline ? 0.11 : 0.085) * size / 2;
  final rgba = Uint8List(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final px = x + 0.5, py = y + 0.5;
      var d = double.infinity;
      for (var i = 0; i < path.length - 1; i++) {
        d = min(
          d,
          _toSegment(
            px,
            py,
            path[i].$1 * size,
            path[i].$2 * size,
            path[i + 1].$1 * size,
            path[i + 1].$2 * size,
          ),
        );
      }
      // One pixel of soft edge, so the mark isn't jagged.
      final ink = (half + 0.5 - d).clamp(0.0, 1.0);
      final o = (y * size + x) * 4;
      if (outline) {
        rgba.setAll(o, [255, 255, 255, (ink * 255).round()]);
      } else {
        int mix(int bg) => (bg + (255 - bg) * ink).round();
        rgba.setAll(o, [mix(accent.$1), mix(accent.$2), mix(accent.$3), 255]);
      }
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
