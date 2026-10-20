/**
 * The brand opening sequence - stage geometry.
 *
 * Pure. Ported from `docs/opening-sequence/source/intro-overlay.html`
 * (section "5. canvas effects", `resize()` at source 350-365 and the `U`
 * constant at source 547).
 */

import { clamp } from './timeline';

export interface StageGeometry {
  /** The stage box in CSS pixels. */
  w: number;
  h: number;
  /** Device pixel ratio, capped at 2 (source 351). */
  dpr: number;
  /** The design unit: `min(w, h) / 100` (source 358, 547). */
  u: number;
  /**
   * Whether the stage is portrait. The lockup is side by side in landscape and
   * stacked in portrait (source 98-100, 355).
   */
  portrait: boolean;
}

export const stageGeometry = (w: number, h: number, dpr: number): StageGeometry => ({
  w,
  h,
  dpr: Math.min(2, dpr || 1),
  u: Math.min(w, h) / 100,
  portrait: h > w,
});

/**
 * The CSS `clamp(min, value, max)` the source uses everywhere (source 59, 71,
 * 73, 78-79, 87, 98). Expressed in the design unit.
 */
export const clampU = (min: number, unit: number, max: number): number =>
  clamp(unit, min, max);
