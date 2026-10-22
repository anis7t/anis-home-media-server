/**
 * The brand opening sequence - the frame.
 *
 * `computeFrame(t)` is the pure heart of the port. It is a faithful port of the
 * DOM-layer half of the archived source's `renderAt(t)`
 * (`docs/opening-sequence/source/intro-overlay.html`, source 495-570), and it
 * is the only place the sequence's state is computed.
 *
 * Two properties matter and are both load-bearing:
 *
 *  1. **It is a pure function of time.** It reads no clock, no DOM and no
 *     random source. That is what makes the frame-for-frame oracle possible
 *     (decision D9 replaced the original's `Math.random()` camera shake).
 *
 *  2. **It returns the source's exact CSS strings.** The original wrote
 *     pre-formatted values - `scale(1.5500) rotate(-7.00deg)`,
 *     `translateY(0.550em)`, `blur(7.00px)` - and the rounding is part of the
 *     rendering. Producing the same strings rather than raw numbers is what
 *     makes the port pixel-identical rather than merely equivalent.
 *
 * The canvas half of the original lives in `fx.ts`; it is a separate function
 * because it draws rather than computes, and because it needs the *measured*
 * position of the mark (source 367-371).
 */

import {
  DURATION,
  T,
  clamp,
  eInOutCubic,
  eOutBack,
  eOutCubic,
  eOutQuint,
  lerp,
  seg,
  shakeAt,
} from './timeline';

export interface LetterState {
  transform: string;
  opacity: string;
}

export interface Frame {
  /** The mark. */
  icon: { transform: string; opacity: string };
  iconGlow: { opacity: string };
  /** "Anis'" - the word container's blur plus each letter's own state. */
  w1: { filter: string; letters: LetterState[] };
  /** "Home Media Server". */
  w2: { filter: string; letters: LetterState[] };
  /** "PLAY - ORGANIZE - ENJOY". */
  sub: { letterSpacing: string; opacity: string; filter: string };
  /** The red rule. */
  rule: { transform: string };
  /** The two curtain halves. */
  veilL: { transform: string; mask: string };
  veilR: { transform: string; mask: string };
  seam: { opacity: string };
  vignette: { opacity: string };
  grain: { opacity: string };
  /** The lockup: the mark, the wordmarks, the subtitle and the rule. */
  lockup: { transform: string; opacity: string };
  /** The camera shake, in pixels. */
  shake: { x: number; y: number };
}

export const WORDMARK_1 = "Anis'";
export const WORDMARK_2 = 'Home Media Server';

/**
 * Split a word into per-letter spans, exactly as the source's
 * `splitLetters` does (source 319-329): one span per character, with a
 * non-breaking space for a real space, so the word never breaks.
 */
export const splitLetters = (text: string): string[] =>
  Array.from(text).map((ch) => (ch === ' ' ? '\u00A0' : ch));

const L1 = splitLetters(WORDMARK_1);
const L2 = splitLetters(WORDMARK_2);

export interface FrameOptions {
  /** The design unit, `min(w, h) / 100`. */
  u: number;
  /** Whether the user asked for reduced motion. */
  reduced: boolean;
}

export const computeFrame = (t: number, opts: FrameOptions): Frame => {
  const { u, reduced } = opts;

  // ── the mark lands (source 504-511) ─────────────────────────────────────────
  const p = seg(t, T.impact - 0.1, T.impact + 0.26);
  const ic = eOutBack(clamp(p, 0, 1));
  const rot = reduced ? 0 : lerp(-7, 0, ic);
  const sc = reduced ? 1 : lerp(1.55, 1, ic);
  const glow = seg(t, T.impact - 0.04, T.impact + 0.3);

  // ── the wordmarks, letter by letter (source 513-529) ────────────────────────
  const wordState = (start: number, duration: number, letters: string[]) => {
    const p0 = seg(t, start, start + duration);
    const blur = lerp(7, 0, eOutCubic(p0));
    return {
      filter: blur > 0.05 ? `blur(${blur.toFixed(2)}px)` : 'none',
      letters: letters.map((_, i) => {
        const delay = i * 0.014;
        const pp = seg(t, start + delay, start + delay + 0.34);
        const e = eOutQuint(pp);
        return {
          transform: `translateY(${lerp(0.55, 0, e).toFixed(3)}em)`,
          opacity: e.toFixed(3),
        };
      }),
    };
  };

  // ── subtitle + rule (source 531-538) ────────────────────────────────────────
  const subP = seg(t, T.sub, T.sub + 0.46);
  const subEase = eOutCubic(subP);
  const subBlur = lerp(5, 0, subEase);
  const ruleP = seg(t, T.rule, T.rule + 0.36);

  // ── the curtain (source 546-557) ────────────────────────────────────────────
  const pk = clamp(seg(t, T.curtain, T.curtainEnd), 0, 1);
  const pke = eInOutCubic(pk);
  // The inner edges only feather once the halves are actually parting, so the
  // opening frames remain one unbroken backdrop (source 552-557).
  const fe = pk <= 0 ? 0 : 4 + 11 * pk;
  const maskL = `linear-gradient(90deg,#000 ${(100 - fe).toFixed(2)}%,transparent 100%)`;
  const maskR = `linear-gradient(270deg,#000 ${(100 - fe).toFixed(2)}%,transparent 100%)`;

  // ── the lockup is dismissed gently (source 566-569) ─────────────────────────
  const pl = eInOutCubic(clamp(seg(t, T.curtain, T.curtain + 0.62), 0, 1));

  // ── the camera shake (source 541-544), made deterministic (D9) ──────────────
  const shake = shakeAt(t, reduced);

  return {
    icon: {
      transform: `scale(${sc.toFixed(4)}) rotate(${rot.toFixed(2)}deg)`,
      opacity: p > 0 ? String(clamp(ic * 1.4, 0, 1)) : '0',
    },
    iconGlow: {
      opacity: p <= 0 ? '0' : String((1 - glow) * 0.95 + 0.16),
    },
    w1: wordState(T.w1, 0.4, L1),
    w2: wordState(T.w2, 0.42, L2),
    sub: {
      letterSpacing: `${lerp(0.62, 0.14, subEase).toFixed(3)}em`,
      opacity: subEase.toFixed(3),
      filter: subBlur > 0.05 ? `blur(${subBlur.toFixed(2)}px)` : 'none',
    },
    rule: {
      transform: `scaleX(${eInOutCubic(ruleP).toFixed(4)})`,
    },
    veilL: {
      transform: `translate3d(${(-pke * 100).toFixed(3)}%,0,0)`,
      mask: maskL,
    },
    veilR: {
      transform: `translate3d(${(pke * 100).toFixed(3)}%,0,0)`,
      mask: maskR,
    },
    seam: {
      opacity: (pk <= 0 ? 0 : Math.pow(Math.sin(Math.min(1, pk * 1.06) * Math.PI), 1.25) * 0.9).toFixed(3),
    },
    vignette: {
      opacity: (1 - pke).toFixed(3),
    },
    grain: {
      opacity: (0.05 * (1 - pke)).toFixed(4),
    },
    lockup: {
      transform:
        `translate(-50%,-50%) translate(${shake.x.toFixed(2)}px,` +
        `${(shake.y - pl * u * 2.4).toFixed(2)}px) scale(${lerp(1, 0.94, pl).toFixed(4)})`,
      opacity: (1 - pl).toFixed(3),
    },
    shake,
  };
};

/** The total length of the sequence (source 278). */
export const INTRO_DURATION = DURATION;
