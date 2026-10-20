import {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useLayoutEffect,
  useRef,
  useState,
} from 'react';
import { createPortal } from 'react-dom';
import type { CSSProperties } from 'react';

import { computeFrame, splitLetters, WORDMARK_1, WORDMARK_2 } from '../../lib/intro/frame';
import { drawFX } from '../../lib/intro/fx';
import { stageGeometry } from '../../lib/intro/geometry';
import type { StageGeometry } from '../../lib/intro/geometry';
import type { IntroMode } from '../../lib/intro/mode';
import { DURATION, HANDOVER_AT, T, clamp } from '../../lib/intro/timeline';
import BrandMark from '../BrandMark';
import './brand-intro.css';

/**
 * The brand opening sequence - the web overlay.
 *
 * A port of the archived canonical overlay
 * (`docs/opening-sequence/source/intro-overlay.html`) onto React. The
 * canonical specification is `docs/OPENING_SEQUENCE.md` Part I.
 *
 * ## How the frames are applied
 *
 * React renders the layer STRUCTURE, once. The per-frame values are written
 * straight to the DOM by the applier, from a `requestAnimationFrame` loop.
 *
 * The obvious alternative - keeping the frame in React state - would re-render
 * this tree sixty times a second across ~22 letter spans, and React 19's
 * concurrent rendering would drop frames. The original made the same choice:
 * it wrote pre-formatted CSS strings straight onto the elements, skipping
 * writes whose value had not changed. `writeStyle()` below is that helper.
 *
 * The consequence is a rule: **no element the applier writes to may carry a
 * React `style` prop**, because React would overwrite it on the next render.
 * The stage's `--u` is therefore written imperatively too.
 *
 * ## Order of operations
 *
 * The canvas is drawn BEFORE the DOM is written, which is what the original
 * did (source 500-501, 567). It matters: the FX are centred on the mark and
 * the sheen sweeps the lockup, and both are measured from the live DOM, so
 * the canvas sees the PREVIOUS frame's geometry. Drawing it after the DOM
 * write would shift every particle by one frame.
 */

const L1 = splitLetters(WORDMARK_1);
const L2 = splitLetters(WORDMARK_2);

export interface BrandIntroOverlayHandle {
  /**
   * Render one exact frame. Stops the playback loop first, so the frame is
   * not immediately overwritten. This is how the frame-for-frame oracle
   * drives the overlay.
   */
  renderAt(t: number): void;
  /** End the sequence now: the layer is removed and `onFinished` fires. */
  finish(): void;
}

export interface BrandIntroOverlayProps {
  /** The mode. See `web/src/lib/intro/mode.ts`. */
  mode: IntroMode;
  /** Called once, when the sequence actually starts. */
  onStarted?: () => void;
  /** Called once, when the sequence has finished. */
  onFinished?: () => void;
}

/** Write a style only when it has actually changed (source 335). */
const writeStyle = (node: HTMLElement | null, key: string, value: string): void => {
  if (!node) return;
  const cache = node as HTMLElement & { _introStyle?: Record<string, string> };
  if (!cache._introStyle) cache._introStyle = {};
  if (cache._introStyle[key] === value) return;
  cache._introStyle[key] = value;
  // Custom properties are not reachable as indexed properties on
  // CSSStyleDeclaration - assigning `style['--u']` silently does nothing, and
  // the whole composition then falls back to the CSS `1vmin` default, which
  // only happens to be right at one viewport size.
  if (key.startsWith('--')) {
    node.style.setProperty(key, value);
    return;
  }
  (node.style as unknown as Record<string, string>)[key] = value;
};

/**
 * The phases the overlay can be in.
 *
 * - `gate` - the manual-testing card is up. Nothing is playing.
 * - `playing` - the sequence is running.
 * - `idle` - the capture mode: present and static, driven from outside.
 * - `done` - finished; the layer has been removed.
 */
type Phase = 'gate' | 'playing' | 'idle' | 'done';

const BrandIntroOverlay = forwardRef<BrandIntroOverlayHandle, BrandIntroOverlayProps>(
  function BrandIntroOverlay({ mode, onStarted, onFinished }, ref) {
    const stageRef = useRef<HTMLDivElement | null>(null);
    const fxRef = useRef<HTMLCanvasElement | null>(null);
    const iconRef = useRef<HTMLSpanElement | null>(null);
    const iconGlowRef = useRef<HTMLDivElement | null>(null);
    const w1Ref = useRef<HTMLDivElement | null>(null);
    const w2Ref = useRef<HTMLDivElement | null>(null);
    const subRef = useRef<HTMLDivElement | null>(null);
    const ruleRef = useRef<HTMLDivElement | null>(null);
    const veilLRef = useRef<HTMLDivElement | null>(null);
    const veilRRef = useRef<HTMLDivElement | null>(null);
    const seamRef = useRef<HTMLDivElement | null>(null);
    const vignetteRef = useRef<HTMLDivElement | null>(null);
    const grainRef = useRef<HTMLDivElement | null>(null);
    const lockupRef = useRef<HTMLDivElement | null>(null);
    const letterRefs = useRef<(HTMLSpanElement | null)[]>([]);

    const rafRef = useRef(0);
    const finishedRef = useRef(false);
    const startedRef = useRef(false);
    const onStartedRef = useRef(onStarted);
    const onFinishedRef = useRef(onFinished);
    onStartedRef.current = onStarted;
    onFinishedRef.current = onFinished;

    const [phase, setPhase] = useState<Phase>(() => {
      if (mode === 'gate') return 'gate';
      if (mode === 'capture') return 'idle';
      return 'playing';
    });
    const [gateClosing, setGateClosing] = useState(false);
    const [gateGone, setGateGone] = useState(false);
    const gateTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

    const [geo, setGeo] = useState<StageGeometry>(() =>
      stageGeometry(
        typeof window === 'undefined' ? 0 : window.innerWidth,
        typeof window === 'undefined' ? 0 : window.innerHeight,
        typeof window === 'undefined' ? 1 : window.devicePixelRatio,
      ),
    );
    const [portrait, setPortrait] = useState(() => geo.portrait);

    /*
     * Reduced motion is a cross-target contract (decision D11). The source
     * reads it once at load (source 331-332); this listens for changes, which
     * is the same behaviour with a better failure mode.
     */
    const [reduced, setReduced] = useState(() => {
      if (typeof window === 'undefined' || !window.matchMedia) return false;
      try {
        return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
      } catch {
        return false;
      }
    });

    useEffect(() => {
      if (typeof window === 'undefined' || !window.matchMedia) return;
      const mq = window.matchMedia('(prefers-reduced-motion: reduce)');
      const onChange = () => setReduced(mq.matches);
      mq.addEventListener('change', onChange);
      return () => mq.removeEventListener('change', onChange);
    }, []);

    /** Re-measure the stage and re-rasterise the canvas (source 350-365). */
    const measure = useCallback(() => {
      const stage = stageRef.current;
      if (!stage) return;
      const rect = stage.getBoundingClientRect();
      const next = stageGeometry(
        Math.round(rect.width),
        Math.round(rect.height),
        typeof window === 'undefined' ? 1 : window.devicePixelRatio,
      );
      // The design unit is published to CSS as `--u` (source 358).
      writeStyle(stage, '--u', `${next.u}px`);
      const canvas = fxRef.current;
      if (canvas) {
        canvas.width = Math.round(next.w * next.dpr);
        canvas.height = Math.round(next.h * next.dpr);
      }
      setGeo(next);
      setPortrait(next.portrait);
    }, []);

    useLayoutEffect(() => {
      measure();
      if (typeof window === 'undefined') return;
      window.addEventListener('resize', measure);
      return () => window.removeEventListener('resize', measure);
    }, [measure]);

    /**
     * Apply one frame. Draws the canvas first, then writes the DOM - see the
     * note on order of operations above.
     */
    const applyFrame = useCallback(
      (t: number) => {
        const stage = stageRef.current;
        if (!stage) return;

        const stageRect = stage.getBoundingClientRect();
        const iconRect = iconRef.current?.getBoundingClientRect() ?? null;
        const lockupRect = lockupRef.current?.getBoundingClientRect() ?? null;

        const canvas = fxRef.current;
        const ctx = canvas?.getContext('2d') ?? null;
        if (ctx) {
          drawFX(
            ctx,
            t,
            {
              w: geo.w,
              h: geo.h,
              dpr: geo.dpr,
              stageLeft: stageRect.left,
              stageTop: stageRect.top,
              iconRect: iconRect ? { ...iconRect.toJSON() } : null,
              lockupRect: lockupRect ? { ...lockupRect.toJSON() } : null,
            },
            reduced,
          );
        }

        const f = computeFrame(t, { u: geo.u, reduced });

        writeStyle(iconRef.current, 'transform', f.icon.transform);
        writeStyle(iconRef.current, 'opacity', f.icon.opacity);
        writeStyle(iconGlowRef.current, 'opacity', f.iconGlow.opacity);

        writeStyle(w1Ref.current, 'filter', f.w1.filter);
        f.w1.letters.forEach((letter, i) => {
          const node = letterRefs.current[i];
          writeStyle(node, 'transform', letter.transform);
          writeStyle(node, 'opacity', letter.opacity);
        });

        const w2Offset = L1.length;
        writeStyle(w2Ref.current, 'filter', f.w2.filter);
        f.w2.letters.forEach((letter, i) => {
          const node = letterRefs.current[w2Offset + i];
          writeStyle(node, 'transform', letter.transform);
          writeStyle(node, 'opacity', letter.opacity);
        });

        writeStyle(subRef.current, 'letterSpacing', f.sub.letterSpacing);
        writeStyle(subRef.current, 'opacity', f.sub.opacity);
        writeStyle(subRef.current, 'filter', f.sub.filter);

        writeStyle(ruleRef.current, 'transform', f.rule.transform);

        writeStyle(veilLRef.current, 'transform', f.veilL.transform);
        writeStyle(veilLRef.current, 'webkitMaskImage', f.veilL.mask);
        writeStyle(veilLRef.current, 'maskImage', f.veilL.mask);
        writeStyle(veilRRef.current, 'transform', f.veilR.transform);
        writeStyle(veilRRef.current, 'webkitMaskImage', f.veilR.mask);
        writeStyle(veilRRef.current, 'maskImage', f.veilR.mask);

        writeStyle(seamRef.current, 'opacity', f.seam.opacity);
        writeStyle(vignetteRef.current, 'opacity', f.vignette.opacity);
        writeStyle(grainRef.current, 'opacity', f.grain.opacity);

        writeStyle(lockupRef.current, 'transform', f.lockup.transform);
        writeStyle(lockupRef.current, 'opacity', f.lockup.opacity);

        // The app underneath is interactive from here on (source 840, 190).
        if (t >= HANDOVER_AT) stage.classList.add('intro-handover');
      },
      [geo, reduced],
    );

    const stopLoop = useCallback(() => {
      if (rafRef.current) {
        cancelAnimationFrame(rafRef.current);
        rafRef.current = 0;
      }
    }, []);

    const finish = useCallback(() => {
      if (finishedRef.current) return;
      finishedRef.current = true;
      stopLoop();
      const stage = stageRef.current;
      if (stage) {
        writeStyle(stage, 'display', 'none');
        stage.classList.remove('intro-handover');
      }
      setPhase('done');
      onFinishedRef.current?.();
    }, [stopLoop]);

    useImperativeHandle(
      ref,
      () => ({
        renderAt(t: number) {
          stopLoop();
          applyFrame(t);
        },
        finish() {
          stopLoop();
          finish();
        },
      }),
      [applyFrame, finish, stopLoop],
    );

    /*
     * The first frame is painted at mount, in every mode, so that nothing
     * flashes before playback starts (source 964-965). In the capture mode
     * this is the ONLY frame the overlay paints on its own.
     */
    useEffect(() => {
      applyFrame(0);
    }, [applyFrame]);

    /* The sequence starts. Reported once, so the container can record it. */
    useEffect(() => {
      if (phase !== 'playing' || startedRef.current) return;
      startedRef.current = true;
      onStartedRef.current?.();
    }, [phase]);

    /* The playback loop. */
    useEffect(() => {
      if (phase !== 'playing') return;
      // The source starts the clock 120 ms in the future, so the first frame
      // is a real frame rather than a half-drawn one (source 849).
      const t0 = performance.now() + 120;
      const loop = (now: number) => {
        rafRef.current = requestAnimationFrame(loop);
        const t = (now - t0) / 1000;
        applyFrame(clamp(t, 0, 4));
        if (t >= DURATION) {
          stopLoop();
          finish();
        }
      };
      rafRef.current = requestAnimationFrame(loop);
      return stopLoop;
    }, [applyFrame, finish, phase, stopLoop]);

    /*
     * Dismissal. The canonical specification says a click, a tap, the space
     * key or ANY key dismisses the sequence (spec Part I section 8).
     *
     * The original's own check was `e.target === el.stage`, which never fired:
     * the FX canvas (z-index 4) and the curtain halves (z-index 2) have no
     * `pointer-events: none`, so a click always landed on one of them and
     * never on the stage. The port listens on the stage itself and lets the
     * event bubble, so a click anywhere on the overlay dismisses - which is
     * also what the Flutter client does.
     *
     * After the handover the stage releases the pointer (source 190), so the
     * app underneath becomes clickable and a click there does NOT dismiss.
     */
    useEffect(() => {
      if (phase !== 'playing') return;
      const stage = stageRef.current;
      if (!stage) return;
      const onPointerDown = () => finish();
      const onKeyDown = (event: KeyboardEvent) => {
        if (event.key === 'Tab') return;
        finish();
      };
      stage.addEventListener('pointerdown', onPointerDown);
      window.addEventListener('keydown', onKeyDown);
      return () => {
        stage.removeEventListener('pointerdown', onPointerDown);
        window.removeEventListener('keydown', onKeyDown);
      };
    }, [finish, phase]);

    /*
     * The capture mode's handle.
     *
     * It is exposed ONLY in `?intro=capture` - a verification surface - and
     * under an underscore-prefixed name to mark it internal. The shape is the
     * original's, so the existing capture tooling needs only a one-line
     * change to drive the port instead of the archived overlay.
     */
    useEffect(() => {
      if (mode !== 'capture' || typeof window === 'undefined') return;
      const api = {
        renderAt: (t: number) => {
          stopLoop();
          applyFrame(t);
        },
        timeline: T,
        duration: DURATION,
        pageMode: () => mode,
      };
      (window as unknown as Record<string, unknown>).__INTRO__ = api;
      return () => {
        delete (window as unknown as Record<string, unknown>).__INTRO__;
      };
    }, [applyFrame, mode, stopLoop]);

    /* The gate's exit: the card fades, then goes (source 851-853). */
    const startFromGate = useCallback(() => {
      setGateClosing(true);
      gateTimerRef.current = setTimeout(() => setGateGone(true), 320);
      setPhase('playing');
    }, []);

    useEffect(
      () => () => {
        if (gateTimerRef.current) clearTimeout(gateTimerRef.current);
      },
      [],
    );

    if (typeof document === 'undefined' || mode === 'off') return null;

    const stageClass = [
      'intro-stage',
      mode === 'capture' ? 'intro-capture' : '',
    ]
      .filter(Boolean)
      .join(' ');

    return createPortal(
      <>
        <div className={stageClass} ref={stageRef}>
          {/* the curtain: two halves of one backdrop */}
          <div className="intro-veil intro-veil-l" ref={veilLRef}>
            <div className="intro-veil-inner" />
          </div>
          <div className="intro-veil intro-veil-r" ref={veilRRef}>
            <div className="intro-veil-inner" />
          </div>
          <div className="intro-seam" ref={seamRef} />

          <canvas className="intro-fx" ref={fxRef} aria-hidden="true" />

          <div className="intro-vignette" ref={vignetteRef} />
          <div className="intro-grain" ref={grainRef} />

          {/* the brand lockup, dismissed gently as the curtain opens */}
          <div
            className={portrait ? 'intro-lockup intro-lockup-portrait' : 'intro-lockup'}
            ref={lockupRef}
            aria-hidden="true"
          >
            <div className="intro-icon-wrap">
              <div className="intro-icon-glow" ref={iconGlowRef} />
              <span className="intro-icon" ref={iconRef}>
                {/* No class: the mark must take its size and its baseline
                    alignment from the browser, exactly as the original's does. */}
                <BrandMark className="" />
              </span>
            </div>
            <div className="intro-word-col">
              <div className="intro-word intro-w1" ref={w1Ref}>
                {L1.map((ch, i) => (
                  <span
                    key={`w1-${i}`}
                    className="intro-lt"
                    ref={(el) => {
                      letterRefs.current[i] = el;
                    }}
                  >
                    {ch}
                  </span>
                ))}
              </div>
              <div className="intro-word intro-w2" ref={w2Ref}>
                {L2.map((ch, i) => (
                  <span
                    key={`w2-${i}`}
                    className="intro-lt"
                    ref={(el) => {
                      letterRefs.current[L1.length + i] = el;
                    }}
                  >
                    {ch}
                  </span>
                ))}
              </div>
              <div className="intro-sub" ref={subRef}>
                PLAY • ORGANIZE • ENJOY
              </div>
              <div className="intro-rule" ref={ruleRef} />
            </div>
          </div>
        </div>

        {/* The gate: the manual-testing card. Never the product behaviour. */}
        {phase === 'gate' && !gateGone ? (
          <div className={`intro-gate${gateClosing ? ' intro-gate-closing' : ''}`}>
            <div className="intro-gate-card">
              <BrandMark className="intro-gate-mark" />
              <h1>
                Anis' <b>Home Media Server</b>
              </h1>
              <p className="intro-gate-sub">Opening sequence · 3 seconds</p>
              <button type="button" className="intro-gate-play" onClick={startFromGate}>
                ▶ Play
              </button>
              <p className="intro-gate-hint">
                The original brand sting. Press play to begin — <kbd>any key</kbd> skips.
              </p>
            </div>
          </div>
        ) : null}
      </>,
      document.body,
    );
  },
);

export default BrandIntroOverlay;

/** The stage's custom property, typed for React's style object. */
export type IntroStageStyle = CSSProperties & { '--u': string };
