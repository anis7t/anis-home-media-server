import { useId } from 'react';

/**
 * The Anis' brand mark.
 *
 * This is the canonical artwork: the exact SVG the brand opening sequence was
 * authored against (`docs/opening-sequence/source/intro-overlay.html`, section
 * "2. brand art (from repo)"). It is the richer of the two marks that existed
 * in the codebase - the app header and the remote-login screen previously
 * carried a simplified re-creation with a single path and no shadow, while the
 * original mark has three paths, a specular highlight and a drop shadow.
 *
 * Phase 11, Slice 11.2 consolidated the two into one, so the app header, the
 * footer and the opening sequence all show the same mark.
 *
 * The gradient and filter ids MUST be unique per instance: the document can
 * hold several copies of this mark at once (the app header plus the opening
 * sequence's overlay, which is portaled to `document.body`), and SVG
 * `url(#id)` references resolve to the FIRST element with that id in the
 * document. The original handled this with a `brandSVG(id)` parameter; this is
 * the React equivalent.
 */
export default function BrandMark({ className = 'h-full w-full' }: { className?: string }) {
  // `useId` is stable across renders and unique per instance. Strip everything
  // that is not valid in a CSS identifier, because the result is interpolated
  // into `url(#...)` references.
  const uid = useId().replace(/[^a-zA-Z0-9]/g, '');
  const pg = `pg${uid}`;
  const ph = `ph${uid}`;
  const ps = `ps${uid}`;

  return (
    <svg viewBox="0 0 36 36" fill="none" className={className} aria-hidden="true">
      <defs>
        <linearGradient id={pg} x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" stopColor="#ff334b" />
          <stop offset="45%" stopColor="#e50914" />
          <stop offset="100%" stopColor="#990014" />
        </linearGradient>
        <linearGradient id={ph} x1="0%" y1="0%" x2="0%" y2="100%">
          <stop offset="0%" stopColor="#ffffff" stopOpacity=".35" />
          <stop offset="100%" stopColor="#ffffff" stopOpacity=".02" />
        </linearGradient>
        <filter id={ps} x="-20%" y="-20%" width="140%" height="140%">
          <feDropShadow dx="0" dy="2" stdDeviation="3" floodColor="#e50914" floodOpacity=".4" />
        </filter>
      </defs>
      <rect width="36" height="36" rx="9" fill="#141822" />
      <rect x=".5" y=".5" width="35" height="35" rx="8.5" stroke="rgba(255,255,255,.08)" />
      <path
        d="M12 9.2C10.7 8.4 9 9.3 9 10.9v14.2c0 1.6 1.7 2.5 3 1.7l13.5-7.1c1.3-.8 1.3-2.6 0-3.4L12 9.2z"
        fill={`url(#${pg})`}
        filter={`url(#${ps})`}
      />
      <path d="M12 9.2C10.7 8.4 9 9.3 9 10.9v8.5l14.2-1.4L12 9.2z" fill={`url(#${ph})`} />
      <path
        d="M12 9.2C10.7 8.4 9 9.3 9 10.9v14.2c0 1.6 1.7 2.5 3 1.7l13.5-7.1c1.3-.8 1.3-2.6 0-3.4L12 9.2z"
        stroke="rgba(255,255,255,.18)"
        strokeWidth=".75"
      />
    </svg>
  );
}
