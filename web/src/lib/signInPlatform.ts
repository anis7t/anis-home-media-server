import { useState } from 'react';

/**
 * Platform inputs used by the header sign-in decision.
 *
 * Kept as a plain object so the helper can be tested without mutating
 * `navigator` (which is read-only in a browser and awkward in jsdom).
 */
export interface SignInPlatformInput {
  readonly userAgent?: string;
  readonly userAgentData?: { readonly mobile?: boolean };
  readonly viewportWidth?: number;
  readonly coarsePointer?: boolean;
}

/**
 * Phone user agents.
 *
 * `Android.+Mobile` deliberately excludes Android tablets, whose UAs carry
 * `Android` but not `Mobile`. iPadOS 13+ reports a desktop Macintosh UA, so it
 * is treated as a non-phone (and therefore keeps the QR option).
 */
const PHONE_USER_AGENT =
  /iPhone|iPod|Windows Phone|IEMobile|Opera Mini|Android.+Mobile|Mobile Safari/i;

/**
 * Whether this browser is a phone.
 *
 * The QR flow is for the device that wants to sign in (a TV/browser) to show
 * a QR that a phone scans. A phone browser is the scanner, not the display,
 * so the header hides the QR option there.
 *
 * There is no reliable web API for "phone vs TV". This helper fails open for
 * an unrecognised user agent: it keeps the QR option rather than removing the
 * only usable sign-in path on a camera-less device. The final coarse-pointer
 * fallback is the one exception: a phone-sized touch viewport is treated as a
 * phone.
 */
export function isPhoneBrowser(
  input: SignInPlatformInput = readSignInPlatform(),
): boolean {
  if (input.userAgentData?.mobile === true) return true;
  if (input.userAgent && PHONE_USER_AGENT.test(input.userAgent)) return true;

  // Last-resort fallback for a phone with an unusual UA: a phone-sized,
  // coarse-pointer viewport. The width is the `sm` breakpoint, not a tablet
  // breakpoint, so a tablet or TV browser is not caught here.
  return (
    input.coarsePointer === true &&
    (input.viewportWidth ?? Number.POSITIVE_INFINITY) < 640
  );
}

/** Reads the browser's current platform inputs, safely outside a browser. */
function readSignInPlatform(): SignInPlatformInput {
  if (typeof navigator === 'undefined') return {};

  const nav = navigator as Navigator & {
    userAgentData?: { readonly mobile?: boolean };
  };
  const viewportWidth = typeof window !== 'undefined' ? window.innerWidth : undefined;
  const coarsePointer =
    typeof window !== 'undefined' && typeof window.matchMedia === 'function'
      ? window.matchMedia('(pointer: coarse)').matches
      : undefined;

  return {
    userAgent: nav.userAgent,
    userAgentData: nav.userAgentData,
    viewportWidth,
    coarsePointer,
  };
}

/**
 * The header's phone decision, evaluated once per mount.
 *
 * It is not a live media-query subscription: a phone does not become a TV
 * when it is rotated, and a resized desktop window should not make the QR
 * option disappear mid-session.
 */
export function useIsPhoneBrowser(): boolean {
  const [isPhone] = useState(() => isPhoneBrowser());
  return isPhone;
}
