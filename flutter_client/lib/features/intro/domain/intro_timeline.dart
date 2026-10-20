/// The brand opening sequence - the timeline and the maths.
///
/// A Dart port of the canonical renderer, `web/src/lib/intro/timeline.ts`,
/// which is itself a faithful port of the archived original
/// (`docs/opening-sequence/source/intro-overlay.html`).
///
/// The canonical specification is `docs/OPENING_SEQUENCE.md` Part I, and the
/// original's source file is the authority on any disagreement.
///
/// Everything in this file is PURE. No clock, no random source, no widget.
/// The camera shake is deterministic on purpose: the original drew it from
/// `Math.random()` (source 541-544), which is what made a reproducible
/// comparison between the two targets impossible (decision D9).
library;

import 'dart:math' as math;

/// The cue times (source 276-278).
class IntroT {
  const IntroT._();

  static const double streak = 0.12;
  static const double impact = 0.62;
  static const double sheen = 0.74;
  static const double w1 = 0.80;
  static const double w2 = 0.92;
  static const double sub = 1.24;
  static const double rule = 1.42;
  static const double settle = 1.58;
  static const double curtain = 1.95;
  static const double curtainEnd = 2.75;
}

/// The sequence's total length (source 278).
const double kIntroDuration = 3.0;

/// The layer hands the app back at `curtain + 0.62` (source 840, 190).
const double kIntroHandoverAt = IntroT.curtain + 0.62;

double clampNum(double v, double a, double b) => v < a ? a : (v > b ? b : v);

double lerpNum(double a, double b, double t) => a + (b - a) * t;

double eOutCubic(double t) => 1 - math.pow(1 - t, 3).toDouble();

double eOutQuint(double t) => 1 - math.pow(1 - t, 5).toDouble();

double eInOutCubic(double t) =>
    t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3).toDouble() / 2;

double eOutBack(double t) {
  const c1 = 1.9;
  const c3 = c1 + 1;
  return 1 + c3 * math.pow(t - 1, 3).toDouble() + c1 * math.pow(t - 1, 2).toDouble();
}

/// Progress of `t` through the window `[a, b]` (source 257).
double seg(double t, double a, double b) =>
    b <= a ? (t >= b ? 1 : 0) : clampNum((t - a) / (b - a), 0, 1);

/// The source's PRNG (source 258).
///
/// Note the shape: the whole body is INSIDE the returned closure, so `a` is
/// incremented and the mixing is redone on every call. Hoisting the
/// initialisation out of the closure - the obvious "tidier" port - produces a
/// completely different sequence, and every particle in the sequence then lands
/// somewhere else.
///
/// **The 32-bit semantics are load-bearing.** The source's `a |= 0` and
/// `Math.imul` are JavaScript's int32 coercions, and Dart's ints are 64-bit.
/// The state is therefore kept as an *unsigned* 32-bit value throughout, and
/// every multiply is masked to 32 bits. The unsigned and the signed
/// interpretations agree on every operation the algorithm performs, because
/// the only signed-only step (`| 0`) is immediately followed by an unsigned
/// shift.
double Function() mulberry32(int seed) {
  var a = seed & 0xffffffff;
  return () {
    a = (a + 0x6d2b79f5) & 0xffffffff;
    final t0 = imul32(a ^ (a >>> 15), 1 | a);
    final t1 = imul32(t0 ^ (t0 >>> 7), 61 | t0);
    // The source's `^` coerces both operands to int32, so only the low 32
    // bits of the sum survive.
    final t = ((((t0 + t1) & 0xffffffff) ^ t0) & 0xffffffff);
    return (t ^ (t >>> 14)) / 4294967296.0;
  };
}

/// JavaScript's `Math.imul`: the low 32 bits of the product, unsigned.
///
/// Dart's `int` is 64-bit and overflows, so the product is assembled from
/// 16-bit halves rather than computed and masked.
int imul32(int a, int b) {
  final x = a & 0xffffffff;
  final y = b & 0xffffffff;
  final lo = (x & 0xffff) * (y & 0xffff);
  final mid = ((x >> 16) & 0xffff) * (y & 0xffff) +
      (x & 0xffff) * ((y >> 16) & 0xffff);
  return (lo + ((mid & 0xffff) << 16)) & 0xffffffff;
}

/// A colour, as the source's three channels (source 341-343).
class IntroRgb {
  const IntroRgb(this.r, this.g, this.b);

  final double r;
  final double g;
  final double b;
}

IntroRgb _pickColor(double v) {
  if (v < 0.66) return const IntroRgb(255, 255, 255);
  if (v < 0.9) return const IntroRgb(255, 64, 84);
  return const IntroRgb(120, 190, 255);
}

/// A particle converging on the mark (source 394-407).
class ConvergingParticle {
  const ConvergingParticle({
    required this.a,
    required this.r0,
    required this.s,
    required this.sp,
    required this.c,
  });

  /// Angle around the mark.
  final double a;

  /// Start radius, as a fraction of the stage diagonal.
  final double r0;

  /// Stroke width.
  final double s;

  /// Speed, and how bright the streak is.
  final double sp;

  final IntroRgb c;
}

/// An ember (source 459-472).
class Ember {
  const Ember({
    required this.x,
    required this.y,
    required this.s,
    required this.c,
    required this.sp,
    required this.ph,
    required this.f,
    required this.dx,
  });

  final double x;
  final double y;
  final double s;
  final IntroRgb c;
  final double sp;
  final double ph;
  final double f;
  final double dx;
}

/// The seeded particle fields (source 341-347).
///
/// They are seeded once, from a fixed sequence, so they are identical on every
/// run and on every machine. They are the reason the FX are reproducible -
/// and the reason the Flutter client and the web draw the *same* particles.
///
/// **The draws are taken in a written order, deliberately.** Each field reads
/// the next value from the stream, so the order is the sequence. Dart does not
/// promise that a constructor's named arguments are evaluated left to right,
/// and when they are not, every particle lands somewhere else - which is the
/// same trap the source's own `mulberry32` comment warns about.
List<ConvergingParticle> buildConverging() {
  final out = <ConvergingParticle>[];
  for (var i = 0; i < 170; i++) {
    final r = mulberry32(i * 2654435761 + 7);
    final a = r() * math.pi * 2;
    final r0 = 0.42 + 0.72 * r();
    final s = 0.7 + 2.1 * r();
    final sp = 0.55 + 0.9 * r();
    final c = _pickColor(r());
    out.add(ConvergingParticle(a: a, r0: r0, s: s, sp: sp, c: c));
  }
  return out;
}

List<Ember> buildEmbers() {
  final out = <Ember>[];
  for (var i = 0; i < 64; i++) {
    final r = mulberry32(i * 97531 + 13);
    final x = r();
    final y = r();
    final s = 0.5 + 1.6 * r();
    final c = _pickColor(r());
    final sp = 5 + 16 * r();
    final ph = r() * 6.283;
    final f = 0.5 + 1.7 * r();
    final dx = 0.3 + 0.7 * r();
    out.add(Ember(x: x, y: y, s: s, c: c, sp: sp, ph: ph, f: f, dx: dx));
  }
  return out;
}

final List<ConvergingParticle> kConverging = buildConverging();
final List<Ember> kEmbers = buildEmbers();

/// The camera shake's peak amplitude, in pixels (source 541-544).
const double kShakeAmplitude = 9;

/// A deterministic 0..1 hash of an integer, salted.
///
/// The web's `hash01` (`web/src/lib/intro/timeline.ts`) and this are the same
/// function, and they MUST stay the same: the two targets have to shake
/// identically, or the shake window could never be compared.
double hash01(int n, int salt) {
  var x = imul32(n ^ salt, 0x27d4eb2d);
  x ^= x >>> 15;
  x = imul32(x, 0x85ebca6b);
  x ^= x >>> 13;
  x = imul32(x, 0xc2b2ae35);
  x ^= x >>> 16;
  return x / 4294967296.0;
}

/// The camera shake at time `t` (source 541-544), made deterministic (D9).
///
/// Zero outside the impact window, and bounded by 9 px inside it, exactly as
/// the original.
class IntroShake {
  const IntroShake(this.x, this.y);

  final double x;
  final double y;

  static const IntroShake zero = IntroShake(0, 0);
}

/// The shake at time `t`.
IntroShake shakeAt(double t, bool reduced) {
  if (reduced || t < IntroT.impact || t >= IntroT.impact + 0.42) {
    return IntroShake.zero;
  }
  final sq = 1 - seg(t, IntroT.impact, IntroT.impact + 0.42);
  final amp = kShakeAmplitude * sq * sq;
  final ms = (t * 1000).round();
  final r1 = hash01(ms, 0x9e3779b9);
  final r2 = hash01(ms, 0x85ebca6b);
  return IntroShake((r1 * 2 - 1) * amp, (r2 * 2 - 1) * amp);
}
