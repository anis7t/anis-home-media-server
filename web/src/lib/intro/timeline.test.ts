import { describe, expect, it } from 'vitest';

import {
  CONV,
  DURATION,
  EMB,
  HANDOVER_AT,
  T,
  clamp,
  eInOutCubic,
  eOutBack,
  eOutCubic,
  eOutQuint,
  lerp,
  mulberry32,
  seg,
  shakeAt,
  shakeDraws,
} from './timeline';

/**
 * The timeline and the maths.
 *
 * These are the values the archived canonical source defines
 * (`docs/opening-sequence/source/intro-overlay.html`, sections 0 and 1). The
 * golden numbers below were produced by the source's own algorithm, so a
 * change to any of them is a change to the design.
 */
describe('the timeline', () => {
  it('is the source\'s cue table', () => {
    expect(T).toEqual({
      streak: 0.12,
      impact: 0.62,
      sheen: 0.74,
      w1: 0.8,
      w2: 0.92,
      sub: 1.24,
      rule: 1.42,
      settle: 1.58,
      curtain: 1.95,
      curtainEnd: 2.75,
    });
    expect(DURATION).toBe(3);
  });

  it('hands the app back at curtain + 0.62', () => {
    expect(HANDOVER_AT).toBe(2.57);
    expect(HANDOVER_AT).toBe(T.curtain + 0.62);
    // The app is interactive for the last 0.43 s of the sequence.
    expect(DURATION - HANDOVER_AT).toBeCloseTo(0.43, 10);
  });
});

describe('the maths', () => {
  it('clamps and interpolates', () => {
    expect(clamp(5, 0, 1)).toBe(1);
    expect(clamp(-5, 0, 1)).toBe(0);
    expect(clamp(0.5, 0, 1)).toBe(0.5);
    expect(lerp(0, 10, 0.25)).toBe(2.5);
  });

  it('has the source\'s easings', () => {
    for (const ease of [eOutCubic, eOutQuint, eInOutCubic, eOutBack]) {
      expect(ease(0)).toBeCloseTo(0, 10);
      expect(ease(1)).toBeCloseTo(1, 10);
    }
    expect(eInOutCubic(0.5)).toBeCloseTo(0.5, 10);
    // eOutBack overshoots past 1 before settling - that is the point of it.
    expect(eOutBack(0.7)).toBeGreaterThan(1);
  });

  it('measures progress through a window', () => {
    expect(seg(0, 1, 2)).toBe(0);
    expect(seg(1, 1, 2)).toBe(0);
    expect(seg(1.5, 1, 2)).toBe(0.5);
    expect(seg(2, 1, 2)).toBe(1);
    expect(seg(9, 1, 2)).toBe(1);
    // A zero-length window is a step.
    expect(seg(5, 1, 1)).toBe(1);
    expect(seg(0, 1, 1)).toBe(0);
  });
});

describe('the seeded fields', () => {
  it('reproduces the source\'s PRNG exactly', () => {
    // The source's `mulberry32` re-seeds and re-mixes on EVERY call - the
    // whole body is inside the returned closure. Hoisting the initialisation
    // out of it produces a different sequence, and every particle in the
    // sequence then lands somewhere else.
    const r = mulberry32(7);
    const first = [r(), r(), r(), r(), r()];
    expect(first).toEqual([
      0.011704753153026104, 0.06195825757458806, 0.97690763277933, 0.6990287057124078,
      0.5214452685322613,
    ]);
  });

  it('seeds the converging particles as the source does', () => {
    expect(CONV).toHaveLength(170);
    expect(CONV[0]).toEqual({
      a: 0.07354313303525756,
      r0: 0.4646099454537034,
      s: 2.7515060288365927,
      sp: 1.179125835141167,
      c: [255, 255, 255],
    });
  });

  it('seeds the embers as the source does', () => {
    expect(EMB).toHaveLength(64);
    expect(EMB[0]).toEqual({
      x: 0.5663226493634284,
      y: 0.36011716164648533,
      s: 0.6129453524947166,
      c: [255, 255, 255],
      sp: 5.588333889842033,
      ph: 0.04255931805586442,
      f: 0.6550526666222141,
      dx: 0.5479217087151482,
    });
  });
});

describe('the camera shake', () => {
  it('is zero outside the impact window', () => {
    expect(shakeAt(0, false)).toEqual({ x: 0, y: 0 });
    expect(shakeAt(0.6, false)).toEqual({ x: 0, y: 0 });
    expect(shakeAt(1.04, false)).toEqual({ x: 0, y: 0 });
    expect(shakeAt(2, false)).toEqual({ x: 0, y: 0 });
  });

  it('is never more than 9 px', () => {
    for (let t = T.impact; t < T.impact + 0.42; t += 0.005) {
      const s = shakeAt(t, false);
      expect(Math.abs(s.x)).toBeLessThanOrEqual(9);
      expect(Math.abs(s.y)).toBeLessThanOrEqual(9);
    }
  });

  it('follows the source\'s amplitude curve', () => {
    // amp = 9 * (1 - progress)^2, so the shake decays quadratically.
    for (const t of [0.62, 0.7, 0.8, 0.9, 1.0]) {
      const sq = 1 - seg(t, T.impact, T.impact + 0.42);
      const amp = 9 * sq * sq;
      const s = shakeAt(t, false);
      expect(Math.abs(s.x)).toBeLessThanOrEqual(amp + 1e-9);
      expect(Math.abs(s.y)).toBeLessThanOrEqual(amp + 1e-9);
    }
  });

  it('is deterministic - the same instant always shakes the same way', () => {
    for (const t of [0.62, 0.75, 0.9, 1.03]) {
      expect(shakeAt(t, false)).toEqual(shakeAt(t, false));
    }
  });

  it('is suppressed by reduced motion', () => {
    for (let t = T.impact; t < T.impact + 0.42; t += 0.01) {
      expect(shakeAt(t, true)).toEqual({ x: 0, y: 0 });
    }
  });

  it('draws two values in [0, 1)', () => {
    for (const t of [0, 0.62, 0.9, 1.03, 3]) {
      const [a, b] = shakeDraws(t);
      expect(a).toBeGreaterThanOrEqual(0);
      expect(a).toBeLessThan(1);
      expect(b).toBeGreaterThanOrEqual(0);
      expect(b).toBeLessThan(1);
    }
  });
});
