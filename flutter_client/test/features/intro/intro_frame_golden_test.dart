import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_server_client/features/intro/domain/intro_frame.dart';

/// The canonical frame fixture.
///
/// It is generated from the CANONICAL implementation - the web renderer, which
/// is pixel-identical to the archived original - by
/// `scripts/gen-intro-frame-golden.mjs`, and it records the values that
/// implementation *rendered*, parsed out of the strings it wrote to the DOM.
///
/// The rounding is part of the rendering, so the port rounds the same way.
const String kFixturePath = '../docs/opening-sequence/frame-golden.json';

/// The tolerance.
///
/// The port and the canonical run the same arithmetic in the same order, in
/// IEEE-754 doubles, so they agree to the last bit. A tolerance of 1e-9 is
/// seven orders of magnitude looser than the arithmetic's own error and far
/// tighter than anything visible.
const double kEpsilon = 1e-9;

void main() {
  final fixtureFile = File(kFixturePath);
  if (!fixtureFile.existsSync()) {
    fail(
      'The canonical frame fixture is missing: $kFixturePath\n'
      'Generate it with:  node scripts/gen-intro-frame-golden.mjs',
    );
  }
  final fixture = jsonDecode(fixtureFile.readAsStringSync())
      as Map<String, dynamic>;
  final u = (fixture['u'] as num).toDouble();
  final frames = (fixture['frames'] as List).cast<Map<String, dynamic>>();

  /// Assert that the port's value and the canonical's agree.
  void expectSame(double actual, num expected, String what, double t) {
    final e = expected.toDouble();
    if ((actual - e).abs() > kEpsilon) {
      fail('at t=$t, $what: the port says $actual, the canonical says $e');
    }
  }

  test('the fixture is not empty', () {
    expect(frames.length, greaterThan(60));
  });

  test('the port computes the canonical frame at every sampled instant', () {
    for (final expected in frames) {
      final t = (expected['t'] as num).toDouble();
      final f = computeIntroFrame(t, IntroFrameOptions(u: u, reduced: false));

      final icon = expected['icon'] as Map<String, dynamic>;
      expectSame(f.iconScale, icon['scale'] as num, 'icon scale', t);
      expectSame(f.iconRotationDeg, icon['rotationDeg'] as num, 'icon rotation', t);
      expectSame(f.iconOpacity, icon['opacity'] as num, 'icon opacity', t);

      final glow = expected['iconGlow'] as Map<String, dynamic>;
      expectSame(f.iconGlowOpacity, glow['opacity'] as num, 'icon glow opacity', t);

      void expectWord(IntroWordState actual, Object raw, String what) {
        final w = raw as Map<String, dynamic>;
        final expectedBlur = w['blurPx'];
        if (expectedBlur == null) {
          expect(actual.blurPx, isNull, reason: 'at t=$t, $what blur');
        } else {
          expect(actual.blurPx, isNotNull, reason: 'at t=$t, $what blur');
          expectSame(actual.blurPx!, expectedBlur as num, '$what blur', t);
        }
        final letters = (w['letters'] as List).cast<Map<String, dynamic>>();
        expect(actual.letters.length, letters.length, reason: 'at t=$t, $what letters');
        for (var i = 0; i < letters.length; i++) {
          expectSame(actual.letters[i].translateYEm, letters[i]['translateYEm'] as num,
              '$what letter $i rise', t);
          expectSame(actual.letters[i].opacity, letters[i]['opacity'] as num,
              '$what letter $i opacity', t);
        }
      }

      expectWord(f.w1, expected['w1'], 'w1');
      expectWord(f.w2, expected['w2'], 'w2');

      final sub = expected['sub'] as Map<String, dynamic>;
      expectSame(f.subLetterSpacingEm, sub['letterSpacingEm'] as num, 'subtitle letter spacing', t);
      expectSame(f.subOpacity, sub['opacity'] as num, 'subtitle opacity', t);
      final subBlur = sub['blurPx'];
      if (subBlur == null) {
        expect(f.subBlurPx, isNull, reason: 'at t=$t, subtitle blur');
      } else {
        expect(f.subBlurPx, isNotNull, reason: 'at t=$t, subtitle blur');
        expectSame(f.subBlurPx!, subBlur as num, 'subtitle blur', t);
      }

      final rule = expected['rule'] as Map<String, dynamic>;
      expectSame(f.ruleScaleX, rule['scaleX'] as num, 'rule scale', t);

      final veilL = expected['veilL'] as Map<String, dynamic>;
      expectSame(f.veilLTranslatePct, veilL['translatePct'] as num, 'left veil travel', t);
      expectSame(f.veilFeatherPct, veilL['featherPct'] as num, 'left veil feather', t);
      final veilR = expected['veilR'] as Map<String, dynamic>;
      expectSame(f.veilRTranslatePct, veilR['translatePct'] as num, 'right veil travel', t);
      expectSame(f.veilFeatherPct, veilR['featherPct'] as num, 'right veil feather', t);

      final seam = expected['seam'] as Map<String, dynamic>;
      expectSame(f.seamOpacity, seam['opacity'] as num, 'seam opacity', t);
      final vignette = expected['vignette'] as Map<String, dynamic>;
      expectSame(f.vignetteOpacity, vignette['opacity'] as num, 'vignette opacity', t);
      final grain = expected['grain'] as Map<String, dynamic>;
      expectSame(f.grainOpacity, grain['opacity'] as num, 'grain opacity', t);

      final lockup = expected['lockup'] as Map<String, dynamic>;
      expectSame(f.lockupTranslateXPx, lockup['translateXPx'] as num, 'lockup travel x', t);
      expectSame(f.lockupTranslateYPx, lockup['translateYPx'] as num, 'lockup travel y', t);
      expectSame(f.lockupScale, lockup['scale'] as num, 'lockup scale', t);
      expectSame(f.lockupOpacity, lockup['opacity'] as num, 'lockup opacity', t);

      final shake = expected['shake'] as Map<String, dynamic>;
      expectSame(f.shakeXPx, shake['x'] as num, 'shake x', t);
      expectSame(f.shakeYPx, shake['y'] as num, 'shake y', t);
    }
  });

  test('reduced motion suppresses the shake, the rotation and the scale', () {
    // The canonical's reduced-motion contract is exactly four things: the
    // impact burst, the camera shake, the icon's rotation and the icon's
    // scale. The burst is in the FX painter; these three are here.
    final t = 0.75;
    final full = computeIntroFrame(t, const IntroFrameOptions(u: 10.8, reduced: false));
    final reduced = computeIntroFrame(t, const IntroFrameOptions(u: 10.8, reduced: true));

    expect(reduced.shakeXPx, 0);
    expect(reduced.shakeYPx, 0);
    expect(full.shakeXPx, isNot(0));

    expect(reduced.iconRotationDeg, 0);
    expect(full.iconRotationDeg, isNot(0));

    expect(reduced.iconScale, 1);
    expect(full.iconScale, isNot(1));

    // And nothing else changes.
    expect(reduced.iconOpacity, full.iconOpacity);
    expect(reduced.w1.letters.first.opacity, full.w1.letters.first.opacity);
    expect(reduced.veilLTranslatePct, full.veilLTranslatePct);
    expect(reduced.lockupOpacity, full.lockupOpacity);
  });

  test('the lockup travel scales with the design unit', () {
    // Every field except the lockup's vertical travel is independent of the
    // viewport; the travel is `pl * u * 2.4`.
    const t = 2.2;
    final wide = computeIntroFrame(t, const IntroFrameOptions(u: 20, reduced: false));
    final narrow = computeIntroFrame(t, const IntroFrameOptions(u: 10, reduced: false));
    final delta = (wide.lockupTranslateYPx - narrow.lockupTranslateYPx).abs();
    expect(delta, greaterThan(0.5));
    expect(wide.iconScale, narrow.iconScale);
    expect(wide.grainOpacity, narrow.grainOpacity);
  });
}
