import { describe, expect, it } from 'vitest';

import { computeFrame, splitLetters, WORDMARK_1, WORDMARK_2 } from './frame';
import { T } from './timeline';
import { stageGeometry } from './geometry';

/**
 * The frame.
 *
 * `computeFrame(t)` is the pure heart of the port, and the frame-for-frame
 * oracle (`web/e2e/intro-frame.spec.ts`) proves it renders identically to the
 * archived original. These tests pin the values themselves, so a change to
 * the sequence is a change to a test rather than a change to the picture.
 */

const U = 10.8; // min(1920, 1080) / 100
const opts = { u: U, reduced: false };

describe('the wordmark', () => {
  it('splits into one span per character, with non-breaking spaces', () => {
    expect(splitLetters(WORDMARK_1)).toEqual(['A', 'n', 'i', 's', "'"]);
    expect(splitLetters(WORDMARK_2)).toEqual([
      'H', 'o', 'm', 'e', '\u00A0', 'M', 'e', 'd', 'i', 'a', '\u00A0', 'S', 'e', 'r', 'v', 'e', 'r',
    ]);
  });

  it('staggers the letters 14 ms apart', () => {
    const frame = computeFrame(T.w1 + 0.1, opts);
    // The first letter is further along than the second.
    expect(Number(frame.w1.letters[0].opacity)).toBeGreaterThan(
      Number(frame.w1.letters[1].opacity),
    );
  });
});

describe('the frame', () => {
  it('is a pure function of time', () => {
    const a = computeFrame(1.234, opts);
    const b = computeFrame(1.234, opts);
    expect(a).toEqual(b);
  });

  it('keeps the mark invisible before it lands', () => {
    expect(computeFrame(0, opts).icon.opacity).toBe('0');
    expect(computeFrame(0.5, opts).icon.opacity).toBe('0');
  });

  it('lands the mark at the impact', () => {
    const frame = computeFrame(T.impact, opts);
    expect(frame.icon.opacity).toBe('1');
    // The scale and the rotation are still settling: they run from
    // impact - 0.10 to impact + 0.26.
    expect(frame.icon.transform).toBe('scale(1.0558) rotate(-0.71deg)');
    expect(computeFrame(T.impact + 0.26, opts).icon.transform).toBe(
      'scale(1.0000) rotate(0.00deg)',
    );
  });

  it('holds the curtain closed until the curtain cue', () => {
    expect(computeFrame(T.curtain - 0.01, opts).veilL.transform).toBe('translate3d(0.000%,0,0)');
    expect(computeFrame(T.curtain - 0.01, opts).veilR.transform).toBe('translate3d(0.000%,0,0)');
  });

  it('opens the curtain to the end', () => {
    const frame = computeFrame(T.curtainEnd, opts);
    expect(frame.veilL.transform).toBe('translate3d(-100.000%,0,0)');
    expect(frame.veilR.transform).toBe('translate3d(100.000%,0,0)');
    expect(frame.vignette.opacity).toBe('0.000');
    expect(frame.grain.opacity).toBe('0.0000');
  });

  it('feathers the veil edges only once the halves part', () => {
    expect(computeFrame(T.curtain, opts).veilL.mask).toBe(
      'linear-gradient(90deg,#000 100.00%,transparent 100%)',
    );
    const parting = computeFrame(T.curtain + 0.4, opts);
    expect(parting.veilL.mask).not.toBe(
      'linear-gradient(90deg,#000 100.00%,transparent 100%)',
    );
  });

  it('dismisses the lockup as the curtain opens', () => {
    expect(computeFrame(T.curtain, opts).lockup.opacity).toBe('1.000');
    expect(computeFrame(T.curtain + 0.62, opts).lockup.opacity).toBe('0.000');
  });

  it('lights the seam in the middle of the parting', () => {
    expect(computeFrame(T.curtain, opts).seam.opacity).toBe('0.000');
    expect(Number(computeFrame(T.curtain + 0.4, opts).seam.opacity)).toBeGreaterThan(0);
  });
});

describe('reduced motion', () => {
  it('suppresses exactly four things', () => {
    const normal = computeFrame(T.impact, { u: U, reduced: false });
    const reduced = computeFrame(T.impact, { u: U, reduced: true });

    // The icon neither scales nor rotates.
    expect(reduced.icon.transform).toBe('scale(1.0000) rotate(0.00deg)');
    expect(normal.icon.transform).not.toBe(reduced.icon.transform);

    // The shake is gone.
    expect(reduced.shake).toEqual({ x: 0, y: 0 });
    expect(normal.shake).not.toEqual(reduced.shake);

    // Everything else is untouched: the wordmarks, the subtitle, the rule, the
    // curtain, the seam, the vignette and the grain are all the same.
    expect(reduced.w1).toEqual(normal.w1);
    expect(reduced.w2).toEqual(normal.w2);
    expect(reduced.sub).toEqual(normal.sub);
    expect(reduced.rule).toEqual(normal.rule);
    expect(reduced.veilL).toEqual(normal.veilL);
    expect(reduced.veilR).toEqual(normal.veilR);
    expect(reduced.seam).toEqual(normal.seam);
    expect(reduced.vignette).toEqual(normal.vignette);
    expect(reduced.grain).toEqual(normal.grain);
  });
});

describe('the stage geometry', () => {
  it('publishes the design unit and the portrait breakpoint', () => {
    const landscape = stageGeometry(1920, 1080, 1);
    expect(landscape.u).toBe(10.8);
    expect(landscape.portrait).toBe(false);
    expect(landscape.dpr).toBe(1);

    const portrait = stageGeometry(1080, 1920, 2);
    expect(portrait.u).toBe(10.8);
    expect(portrait.portrait).toBe(true);
    expect(portrait.dpr).toBe(2);
  });

  it('caps the device pixel ratio at 2', () => {
    expect(stageGeometry(1920, 1080, 3).dpr).toBe(2);
    expect(stageGeometry(1920, 1080, 0).dpr).toBe(1);
  });
});
