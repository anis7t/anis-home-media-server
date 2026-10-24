import { describe, expect, it } from 'vitest';

import { IntroScore, RAMP, SCORE } from './audio';
import golden from './score-golden.json';

/**
 * The score.
 *
 * The composition is pinned by `score-golden.json` - a transcription of the
 * archived original's `build(t0)` (source 698-776). The proof that the port
 * plays the same MUSIC is the rendered-audio comparison in
 * `web/e2e/intro-audio.spec.ts`, which measures the port's render against the
 * reference WAV.
 */

describe('the score', () => {
  it('is the composition the original composed', () => {
    expect(SCORE).toEqual(golden.voices);
  });

  it('leads the animation by exactly the ramp', () => {
    // The animation's clock starts 120 ms in the future (source 849) and the
    // score is anchored to the same instant (source 782). RAMP is what makes
    // the two agree - it is not a lead-in for the score.
    expect(RAMP).toBe(0.12);
  });

  it('covers the whole sequence', () => {
    const last = Math.max(...SCORE.map((v) => v.at + v.dur));
    expect(last).toBeGreaterThan(2.9);
    expect(last).toBeLessThanOrEqual(3.1);
  });

  it('has a voice for every cue in the sequence', () => {
    // The room tone, the riser, two hits, the sparkle and the handoff chime.
    expect(SCORE[0].at).toBe(0);
    expect(SCORE.some((v) => v.at === 0.62)).toBe(true);
    expect(SCORE.some((v) => v.at === 1.12)).toBe(true);
    expect(SCORE.some((v) => v.at === 1.58)).toBe(true);
    expect(SCORE.some((v) => v.at === 2.0)).toBe(true);
  });

  it('gives every voice a peak and a pan in range', () => {
    for (const v of SCORE) {
      expect(v.peak).toBeGreaterThan(0);
      expect(v.peak).toBeLessThanOrEqual(0.5);
      expect(v.pan).toBeGreaterThanOrEqual(-1);
      expect(v.pan).toBeLessThanOrEqual(1);
    }
  });
});

describe('the live score', () => {
  it('does not start when there is no Web Audio, and says so', () => {
    // jsdom has no AudioContext. The source's own fail-safe (source 779:
    // `init()` returning false) is what keeps the animation running on a
    // browser with no audio at all.
    const score = new IntroScore();
    expect(score.state).toBe('none');
    expect(score.start(0)).toBe(false);
    expect(score.hasStarted).toBe(false);
  });

  it('drops the score when the animation is over', () => {
    const score = new IntroScore();
    // `onResumed(null)` means "the animation has finished" - the score is
    // dropped rather than orphaned, because a three-second score playing out
    // of nowhere is worse than no score.
    expect(score.onResumed(null)).toBe(false);
    expect(score.hasStarted).toBe(false);
  });

  it('mutes and unmutes', () => {
    const score = new IntroScore();
    expect(score.isMuted).toBe(false);
    expect(score.toggleMute()).toBe(true);
    expect(score.isMuted).toBe(true);
    expect(score.toggleMute()).toBe(false);
  });
});
