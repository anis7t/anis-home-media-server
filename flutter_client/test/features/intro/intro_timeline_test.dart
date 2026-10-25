import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/intro/domain/intro_timeline.dart';

/// The canonical PRNG and the deterministic camera shake.
///
/// The web's renderer and the Flutter client must draw the **same particles**
/// and shake the **same way**, or the two targets are not the same sequence.
/// The original drew its shake from `Math.random()` (source 541-544), which
/// made that impossible - decision D9 made it deterministic, and this test is
/// what keeps the two implementations honest.
///
File _resolveReferenceFile() {
  final candidates = [
    'test/features/intro/fixtures/prng_reference.json',
    'fixtures/prng_reference.json',
    '../web/_prng_capture.json',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) return file;
  }
  return File('test/features/intro/fixtures/prng_reference.json');
}

void main() {
  final file = _resolveReferenceFile();
  if (!file.existsSync()) {
    fail('The PRNG reference is missing: ${file.path}');
  }
  final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  test('the PRNG is the source\'s, bit for bit', () {
    final streams = (raw['streams'] as List).cast<List>();
    for (final stream in streams) {
      final seed = (stream[0] as num).toInt();
      final expected = (stream[1] as List).cast<num>();
      final r = mulberry32(seed);
      for (var i = 0; i < expected.length; i++) {
        expect(r(), expected[i], reason: 'seed $seed, draw $i');
      }
    }
  });

  test('the converging particles are the canonical ones', () {
    final expected = (raw['CONV'] as List).cast<List>();
    expect(kConverging.length, expected.length);
    for (var i = 0; i < expected.length; i++) {
      final e = expected[i].cast<dynamic>();
      final c = kConverging[i];
      expect(c.a, e[0], reason: 'particle $i angle');
      expect(c.r0, e[1], reason: 'particle $i radius');
      expect(c.s, e[2], reason: 'particle $i width');
      expect(c.sp, e[3], reason: 'particle $i speed');
      final rgb = (e[4] as List).cast<num>();
      expect(c.c.r, rgb[0], reason: 'particle $i colour r');
      expect(c.c.g, rgb[1], reason: 'particle $i colour g');
      expect(c.c.b, rgb[2], reason: 'particle $i colour b');
    }
  });

  test('the embers are the canonical ones', () {
    final expected = (raw['EMB'] as List).cast<List>();
    expect(kEmbers.length, expected.length);
    for (var i = 0; i < expected.length; i++) {
      final e = expected[i].cast<dynamic>();
      final m = kEmbers[i];
      expect(m.x, e[0], reason: 'ember $i x');
      expect(m.y, e[1], reason: 'ember $i y');
      expect(m.s, e[2], reason: 'ember $i size');
      final c = (e[3] as List).cast<num>();
      expect(m.c.r, c[0], reason: 'ember $i colour r');
      expect(m.c.g, c[1], reason: 'ember $i colour g');
      expect(m.c.b, c[2], reason: 'ember $i colour b');
      expect(m.sp, e[4], reason: 'ember $i speed');
      expect(m.ph, e[5], reason: 'ember $i phase');
      expect(m.f, e[6], reason: 'ember $i frequency');
      expect(m.dx, e[7], reason: 'ember $i drift');
    }
  });

  test('the camera shake is the canonical one', () {
    final expected = (raw['shakes'] as List).cast<List>();
    for (final row in expected) {
      final t = (row[0] as num).toDouble();
      final s = shakeAt(t, false);
      expect(s.x, row[1], reason: 'shake x at t=$t');
      expect(s.y, row[2], reason: 'shake y at t=$t');
    }
  });

  test('the shake is zero outside the impact window, and under reduced motion', () {
    expect(shakeAt(0.0, false).x, 0);
    expect(shakeAt(0.61, false).x, 0);
    expect(shakeAt(1.05, false).x, 0);
    expect(shakeAt(0.75, true).x, 0);
    expect(shakeAt(0.75, true).y, 0);
  });

  test('the shake is bounded by nine pixels', () {
    for (var ms = 620; ms < 1040; ms += 3) {
      final s = shakeAt(ms / 1000, false);
      expect(s.x.abs(), lessThanOrEqualTo(9.0));
      expect(s.y.abs(), lessThanOrEqualTo(9.0));
    }
  });
}
