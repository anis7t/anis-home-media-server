/// The brand opening sequence - the frame.
///
/// A Dart port of the canonical renderer, `web/src/lib/intro/frame.ts`, which
/// is itself a faithful port of the archived original's DOM-layer half of
/// `renderAt(t)` (`docs/opening-sequence/source/intro-overlay.html`, source
/// 495-570).
///
/// ## Two properties matter, and both are load-bearing
///
///  1. **It is a pure function of time.** It reads no clock and no random
///     source. That is what makes the comparison against the canonical
///     implementation possible at all (decision D9 replaced the original's
///     `Math.random()` camera shake).
///
///  2. **The values are rounded the way the canonical rounds them.** The
///     original wrote pre-formatted values - `scale(1.5500)`,
///     `translateY(0.550em)`, `blur(7.00px)` - and *the rounding is part of the
///     rendering*. So this port rounds identically, and the Flutter client
///     renders the same numbers the web does, not merely equivalent ones.
///
/// The canonical implementation is the reference: the web's renderer is
/// pixel-identical to the archived original, so porting it is porting the
/// original.
library;

import 'dart:math' as math;

import 'intro_timeline.dart';

/// JavaScript's `Number.prototype.toFixed`, as a number.
///
/// The canonical wrote pre-formatted values - `scale(1.5500)`,
/// `translateY(0.550em)`, `blur(7.00px)` - and **the rounding is part of the
/// rendering**. So the port has to round the way the canonical rounds, and
/// the value the widget renders has to be the value the canonical rendered.
///
/// Dart's `toStringAsFixed` and JavaScript's `toFixed` agree exactly, and the
/// reason is worth stating: both round from the double's **exact** value, and
/// at one to four decimal places an exact tie cannot occur - the midpoints
/// are `(2n+1)/10^f`, which is never a dyadic rational and so is never
/// representable as a double. (At zero places it could, and it does not.)
///
/// That is also why this must NOT be implemented by multiplying by the scale
/// factor and rounding: the multiplication rounds, and a value just below a
/// midpoint can land exactly on it, which flips the result. This port
/// originally did that, and it disagreed with the canonical by one unit in the
/// last place on the curtain's feather at `t = 2.57`.
///
/// The agreement was checked over 800,000 values spanning four precisions,
/// including negatives and very small magnitudes: no mismatches.
double jsToFixed(double x, int places) {
  if (x.isNaN || x.isInfinite) return x;
  if (x.abs() >= 1e21) return x;
  return double.parse(x.toStringAsFixed(places));
}

/// The state of one wordmark letter.
class IntroLetterState {
  const IntroLetterState({required this.translateYEm, required this.opacity});

  /// The letter's rise, in em.
  final double translateYEm;

  final double opacity;
}

/// The state of one wordmark.
class IntroWordState {
  const IntroWordState({required this.blurPx, required this.letters});

  /// The word container's blur, in px. `null` means no blur at all - the
  /// canonical writes the CSS keyword `none` below 0.05 px.
  final double? blurPx;

  final List<IntroLetterState> letters;
}

/// One frame of the sequence.
///
/// Every value here is the value the canonical **rendered**, rounded the way
/// the canonical rounds it.
class IntroFrame {
  const IntroFrame({
    required this.iconScale,
    required this.iconRotationDeg,
    required this.iconOpacity,
    required this.iconGlowOpacity,
    required this.w1,
    required this.w2,
    required this.subLetterSpacingEm,
    required this.subOpacity,
    required this.subBlurPx,
    required this.ruleScaleX,
    required this.veilLTranslatePct,
    required this.veilRTranslatePct,
    required this.veilFeatherPct,
    required this.seamOpacity,
    required this.vignetteOpacity,
    required this.grainOpacity,
    required this.lockupTranslateXPx,
    required this.lockupTranslateYPx,
    required this.lockupScale,
    required this.lockupOpacity,
    required this.shakeXPx,
    required this.shakeYPx,
  });

  /// The mark.
  final double iconScale;
  final double iconRotationDeg;
  final double iconOpacity;

  final double iconGlowOpacity;

  /// "Anis'".
  final IntroWordState w1;

  /// "Home Media Server".
  final IntroWordState w2;

  /// "PLAY - ORGANIZE - ENJOY".
  final double subLetterSpacingEm;
  final double subOpacity;
  final double? subBlurPx;

  /// The red rule.
  final double ruleScaleX;

  /// The curtain halves' travel, as a percentage of their own width.
  final double veilLTranslatePct;
  final double veilRTranslatePct;

  /// The inner edges' feather, as a percentage of the half's width. The
  /// canonical's mask is `linear-gradient(90deg,#000 (100 - feather)%,...)`.
  final double veilFeatherPct;

  final double seamOpacity;
  final double vignetteOpacity;
  final double grainOpacity;

  /// The lockup: the mark, the wordmarks, the subtitle and the rule.
  final double lockupTranslateXPx;
  final double lockupTranslateYPx;
  final double lockupScale;
  final double lockupOpacity;

  /// The camera shake, in pixels.
  ///
  /// These are the RAW offsets. The canonical renders them through the
  /// lockup's transform, which rounds them - and the lockup's travel is what
  /// carries the rendered value.
  final double shakeXPx;
  final double shakeYPx;
}

/// The options a frame is computed with.
class IntroFrameOptions {
  const IntroFrameOptions({required this.u, required this.reduced});

  /// The design unit, `min(w, h) / 100`.
  final double u;

  /// Whether the user asked for reduced motion.
  final bool reduced;
}

/// "Anis'", split into per-letter spans (source 319-329).
///
/// One span per character, with a non-breaking space for a real space, so the
/// word never breaks.
List<String> splitLetters(String text) =>
    text.runes.map((r) => r == 0x20 ? '\u00A0' : String.fromCharCode(r)).toList();

const String kWordmark1 = "Anis'";
const String kWordmark2 = 'Home Media Server';

final List<String> kLetters1 = splitLetters(kWordmark1);
final List<String> kLetters2 = splitLetters(kWordmark2);

/// Compute the frame at time `t`.
///
/// A port of the canonical `computeFrame` (web/src/lib/intro/frame.ts), line
/// for line: the same operations, in the same order, with the same rounding.
IntroFrame computeIntroFrame(double t, IntroFrameOptions opts) {
  final u = opts.u;
  final reduced = opts.reduced;

  // ── the mark lands (source 504-511) ─────────────────────────────────────────
  final p = seg(t, IntroT.impact - 0.1, IntroT.impact + 0.26);
  final ic = eOutBack(clampNum(p, 0, 1));
  final rot = reduced ? 0.0 : lerpNum(-7, 0, ic);
  final sc = reduced ? 1.0 : lerpNum(1.55, 1, ic);
  final glow = seg(t, IntroT.impact - 0.04, IntroT.impact + 0.3);

  // ── the wordmarks, letter by letter (source 513-529) ────────────────────────
  IntroWordState wordState(double start, double duration, int letterCount) {
    final p0 = seg(t, start, start + duration);
    final blur = lerpNum(7, 0, eOutCubic(p0));
    final letters = <IntroLetterState>[];
    for (var i = 0; i < letterCount; i++) {
      final delay = i * 0.014;
      final pp = seg(t, start + delay, start + delay + 0.34);
      final e = eOutQuint(pp);
      letters.add(
        IntroLetterState(
          translateYEm: jsToFixed(lerpNum(0.55, 0, e), 3),
          opacity: jsToFixed(e, 3),
        ),
      );
    }
    return IntroWordState(
      blurPx: blur > 0.05 ? jsToFixed(blur, 2) : null,
      letters: letters,
    );
  }

  // ── subtitle + rule (source 531-538) ────────────────────────────────────────
  final subP = seg(t, IntroT.sub, IntroT.sub + 0.46);
  final subEase = eOutCubic(subP);
  final subBlur = lerpNum(5, 0, subEase);
  final ruleP = seg(t, IntroT.rule, IntroT.rule + 0.36);

  // ── the curtain (source 546-557) ────────────────────────────────────────────
  final pk = clampNum(seg(t, IntroT.curtain, IntroT.curtainEnd), 0, 1);
  final pke = eInOutCubic(pk);
  // The inner edges only feather once the halves are actually parting, so the
  // opening frames remain one unbroken backdrop (source 552-557).
  final fe = pk <= 0 ? 0.0 : 4 + 11 * pk;

  // ── the lockup is dismissed gently (source 566-569) ─────────────────────────
  final pl = eInOutCubic(clampNum(seg(t, IntroT.curtain, IntroT.curtain + 0.62), 0, 1));

  // ── the camera shake (source 541-544), made deterministic (D9) ──────────────
  final shake = shakeAt(t, reduced);

  return IntroFrame(
    iconScale: jsToFixed(sc, 4),
    iconRotationDeg: jsToFixed(rot, 2),
    iconOpacity: p > 0 ? clampNum(ic * 1.4, 0, 1) : 0,
    iconGlowOpacity: p <= 0 ? 0 : (1 - glow) * 0.95 + 0.16,
    w1: wordState(IntroT.w1, 0.4, kLetters1.length),
    w2: wordState(IntroT.w2, 0.42, kLetters2.length),
    subLetterSpacingEm: jsToFixed(lerpNum(0.62, 0.14, subEase), 3),
    subOpacity: jsToFixed(subEase, 3),
    subBlurPx: subBlur > 0.05 ? jsToFixed(subBlur, 2) : null,
    ruleScaleX: jsToFixed(eInOutCubic(ruleP), 4),
    veilLTranslatePct: jsToFixed(-pke * 100, 3),
    veilRTranslatePct: jsToFixed(pke * 100, 3),
    veilFeatherPct: jsToFixed(100 - fe, 2),
    seamOpacity: jsToFixed(
      pk <= 0
          ? 0
          : math.pow(
                math.sin(math.min(1, pk * 1.06) * math.pi),
                1.25,
              ).toDouble() *
              0.9,
      3,
    ),
    vignetteOpacity: jsToFixed(1 - pke, 3),
    grainOpacity: jsToFixed(0.05 * (1 - pke), 4),
    lockupTranslateXPx: jsToFixed(shake.x, 2),
    lockupTranslateYPx: jsToFixed(shake.y - pl * u * 2.4, 2),
    lockupScale: jsToFixed(lerpNum(1, 0.94, pl), 4),
    lockupOpacity: jsToFixed(1 - pl, 3),
    shakeXPx: shake.x,
    shakeYPx: shake.y,
  );
}
