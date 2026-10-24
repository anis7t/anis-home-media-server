/**
 * The brand opening sequence - the FX canvas.
 *
 * A faithful port of the archived source's `drawFX(t)`
 * (`docs/opening-sequence/source/intro-overlay.html`, source 372-493): the
 * build-up beams, the particles converging on the mark, the impact burst, the
 * shockwave rings, the impact flash, the standing brand glow, the settling
 * embers and the specular sheen.
 *
 * The drawing is deterministic. The particles and the embers come from seeded
 * fields (`timeline.ts`), and the only random thing the original had - the
 * camera shake - applies to the lockup, not to this canvas.
 *
 * The source's `drawFX` reads the *measured* position of the mark and of the
 * lockup, because the FX are centred on the mark and the sheen sweeps across
 * the lockup. Those rectangles are therefore inputs here rather than
 * something this function looks up. The caller must pass the rectangles as
 * they stood BEFORE this frame's transforms were applied - which is exactly
 * what the original did, and why the source draws the canvas before it writes
 * the DOM (source 500-501, 567).
 */

import { CONV, EMB, T, clamp, eInOutCubic, eOutCubic, eOutQuint, lerp, seg } from './timeline';
import type { Rgb } from './timeline';

export interface Rect {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface FxGeometry {
  /** The stage box in CSS pixels. */
  w: number;
  h: number;
  dpr: number;
  /** The stage's offset in the page, so the mark can be expressed relative to it. */
  stageLeft: number;
  stageTop: number;
  /** The mark's measured rectangle, or null if it has no size yet. */
  iconRect: Rect | null;
  /** The lockup's measured rectangle, or null. */
  lockupRect: Rect | null;
}

const rgba = (c: Rgb, a: number): string =>
  `rgba(${c[0]},${c[1]},${c[2]},${a.toFixed(3)})`;

/**
 * Where the FX are centred: the middle of the mark, or the middle of the
 * stage if the mark has no size yet (source 367-371).
 */
export const fxOrigin = (g: FxGeometry): { x: number; y: number } => {
  if (g.iconRect && g.iconRect.width > 0) {
    return {
      x: g.iconRect.left - g.stageLeft + g.iconRect.width / 2,
      y: g.iconRect.top - g.stageTop + g.iconRect.height / 2,
    };
  }
  return { x: g.w / 2, y: g.h / 2 };
};

export const drawFX = (
  ctx: CanvasRenderingContext2D,
  t: number,
  g: FxGeometry,
  reduced: boolean,
): void => {
  const { w: W, h: H, dpr: DPR } = g;

  ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
  ctx.clearRect(0, 0, W, H);
  ctx.globalCompositeOperation = 'lighter';
  ctx.globalAlpha = 1;

  const diag = Math.sqrt(W * W + H * H);
  const o = fxOrigin(g);
  const cx = o.x;
  const cy = o.y;
  let i: number;
  let p: number;
  let q: number;
  let a: number;
  let x: number;
  let y: number;

  /* build-up light beams (source 378-392) */
  p = seg(t, T.streak, T.impact);
  if (p > 0 && p < 1) {
    for (i = 0; i < 3; i++) {
      const ph = i / 3;
      const px = lerp(-W * 0.35, W * 0.35, (p + ph) % 1);
      const bw = W * 0.09;
      ctx.save();
      ctx.translate(W / 2 + px, H / 2);
      ctx.rotate(-0.22);
      const grad = ctx.createLinearGradient(-bw, 0, bw, 0);
      grad.addColorStop(0, 'rgba(255,255,255,0)');
      grad.addColorStop(0.5, i === 1 ? 'rgba(255,90,110,0.5)' : 'rgba(255,255,255,0.38)');
      grad.addColorStop(1, 'rgba(255,255,255,0)');
      ctx.fillStyle = grad;
      ctx.globalAlpha = 0.3 * Math.sin(p * Math.PI);
      ctx.fillRect(-bw, -diag * 0.8, bw * 2, diag * 1.6);
      ctx.restore();
      ctx.globalAlpha = 1;
    }
  }

  /* particles converging on the mark (source 394-407) */
  p = seg(t, T.streak, T.impact);
  if (p > 0 && p < 1) {
    const R0 = diag * 0.62;
    const e1 = eOutCubic(p);
    const e2 = eOutCubic(Math.max(0, p - 0.07));
    for (i = 0; i < CONV.length; i++) {
      const c = CONV[i];
      const r1 = lerp(c.r0 * R0, diag * 0.008, e1);
      const r2 = lerp(c.r0 * R0, diag * 0.008, e2);
      x = cx + Math.cos(c.a) * r1;
      y = cy + Math.sin(c.a) * r1;
      ctx.strokeStyle = rgba(c.c, clamp(0.1 + 0.55 * e1, 0, 1) * c.sp);
      ctx.lineWidth = c.s * (0.5 + 0.9 * e1);
      ctx.beginPath();
      ctx.moveTo(cx + Math.cos(c.a) * r2, cy + Math.sin(c.a) * r2);
      ctx.lineTo(x, y);
      ctx.stroke();
    }
  }

  /* impact burst (source 409-420) - suppressed under reduced motion */
  q = seg(t, T.impact, T.impact + 0.42);
  if (q > 0 && q < 1 && !reduced) {
    const eb = eOutQuint(q);
    for (i = 0; i < CONV.length; i++) {
      const cb = CONV[i];
      const rb = diag * 0.008 + eb * (cb.r0 * diag * 0.3 + 150);
      x = cx + Math.cos(cb.a) * rb;
      y = cy + Math.sin(cb.a) * rb;
      a = (1 - q) * (1 - q) * 0.85 * cb.sp;
      ctx.fillStyle = rgba(cb.c, a);
      ctx.beginPath();
      ctx.arc(x, y, cb.s * 1.7 * (1 - q * 0.45), 0, 6.283);
      ctx.fill();
    }
  }

  /* shockwave rings (source 422-433) */
  for (i = 0; i < 2; i++) {
    q = seg(t, T.impact + i * 0.07, T.impact + 0.8 + i * 0.07);
    if (q > 0 && q < 1) {
      const rr = eOutQuint(q) * diag * 0.44;
      ctx.beginPath();
      ctx.arc(cx, cy, rr, 0, 6.283);
      ctx.lineWidth = 1 + 7 * (1 - q);
      ctx.strokeStyle = i
        ? `rgba(255,42,75,${(Math.pow(1 - q, 1.6) * 0.75).toFixed(3)})`
        : `rgba(255,255,255,${(Math.pow(1 - q, 1.8) * 0.7).toFixed(3)})`;
      ctx.stroke();
    }
  }

  /* impact flash (source 435-445) */
  q = seg(t, T.impact - 0.05, T.impact + 0.34);
  if (q > 0 && q < 1) {
    a = (q < 0.09 ? q / 0.09 : Math.pow(1 - (q - 0.09) / 0.91, 2.2)) * 0.72;
    const fg = ctx.createRadialGradient(cx, cy, 0, cx, cy, diag * 0.55);
    fg.addColorStop(0, `rgba(255,255,255,${a.toFixed(3)})`);
    fg.addColorStop(0.22, `rgba(255,140,155,${(a * 0.55).toFixed(3)})`);
    fg.addColorStop(0.6, `rgba(229,9,20,${(a * 0.22).toFixed(3)})`);
    fg.addColorStop(1, 'rgba(229,9,20,0)');
    ctx.fillStyle = fg;
    ctx.fillRect(0, 0, W, H);
  }

  /* standing brand glow (source 447-457) */
  p = seg(t, T.impact, T.curtain);
  if (p > 0) {
    const gp = 1 - seg(t, T.curtain, T.curtain + 0.3);
    a = (0.16 + 0.05 * Math.sin(t * 7)) * p * gp;
    const gg = ctx.createRadialGradient(cx, cy, 0, cx, cy, diag * 0.3);
    gg.addColorStop(0, `rgba(255,60,80,${a.toFixed(3)})`);
    gg.addColorStop(0.45, `rgba(229,9,20,${(a * 0.42).toFixed(3)})`);
    gg.addColorStop(1, 'rgba(229,9,20,0)');
    ctx.fillStyle = gg;
    ctx.fillRect(0, 0, W, H);
  }

  /* settling embers (source 459-472) */
  const q2 = seg(t, T.settle - 0.35, T.settle + 0.7);
  if (q2 > 0) {
    const fadeOut = 1 - seg(t, T.curtain + 0.1, T.curtainEnd + 0.05);
    for (i = 0; i < EMB.length; i++) {
      const em = EMB[i];
      const tt = t - 1.2;
      const yn = (((em.y - (tt * em.sp) / H) % 1.4) + 1.4) % 1.4 - 0.2;
      x = (em.x + Math.sin(tt * em.f + em.ph) * 0.02 * em.dx) * W;
      y = yn * H;
      a = q2 * fadeOut * (0.35 + 0.4 * Math.abs(Math.sin(t * em.f * 2 + em.ph))) * 0.8;
      ctx.fillStyle = rgba(em.c, a);
      ctx.beginPath();
      ctx.arc(x, y, em.s, 0, 6.283);
      ctx.fill();
    }
  }

  /* specular sheen sweeping the lockup (source 474-491) */
  q = seg(t, T.sheen, T.sheen + 0.5);
  if (q > 0 && q < 1) {
    const lr = g.lockupRect;
    if (lr && lr.width > 0) {
      ctx.save();
      ctx.translate(
        lr.left - g.stageLeft + lr.width * lerp(-0.25, 1.25, eInOutCubic(q)),
        lr.top - g.stageTop + lr.height / 2,
      );
      ctx.rotate(-0.3);
      const sw = lr.width * 0.3;
      const sh = lr.height * 2.2;
      const sg = ctx.createLinearGradient(-sw, 0, sw, 0);
      sg.addColorStop(0, 'rgba(255,255,255,0)');
      sg.addColorStop(0.5, 'rgba(255,255,255,0.55)');
      sg.addColorStop(1, 'rgba(255,255,255,0)');
      ctx.fillStyle = sg;
      ctx.globalAlpha = Math.sin(q * Math.PI) * 0.85;
      ctx.fillRect(-sw, -sh / 2, sw * 2, sh);
      ctx.restore();
      ctx.globalAlpha = 1;
    }
  }

  ctx.globalCompositeOperation = 'source-over';
};
