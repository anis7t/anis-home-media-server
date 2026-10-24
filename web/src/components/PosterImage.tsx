/**
 * Poster artwork with deliberate loading priority.
 *
 * Follows the image-priority guidance for this project:
 *  - The LCP candidate gets `fetchPriority="high"` and **never** `loading="lazy"`
 *    (combining the two would defeat the priority boost).
 *  - Standard below-the-fold posters get `loading="lazy"` **alone**. They must
 *    NOT also get `fetchPriority="low"` - once scrolled into view they should
 *    load at normal priority, and marking them low defers them unnecessarily.
 *  - `fetchPriority` is omitted entirely for normal-priority images rather than
 *    set to `"auto"`, letting the browser use its own heuristics.
 *  - Explicit `width`/`height` on every poster so the grid reserves its space
 *    and does not shift as images arrive (CLS).
 *
 * `fetchPriority` is a progressive enhancement: a browser that does not support
 * it ignores the attribute, so no fallback branch is needed.
 */
import { useState } from 'react';

export type PosterPriority = 'lcp' | 'lazy' | 'normal';

interface PosterImageProps {
  readonly src: string | null;
  readonly alt: string;
  readonly priority?: PosterPriority;
}

const POSTER_WIDTH = 200;
const POSTER_HEIGHT = 300;

export function PosterImage({ src, alt, priority = 'lazy' }: PosterImageProps) {
  const [failed, setFailed] = useState(false);

  // Reserve the box regardless: a missing poster must not collapse the grid row.
  if (!src || failed) {
    return (
      <div
        className="flex h-full w-full items-center justify-center bg-obsidian-800 text-3xl text-white/25"
        role="img"
        /*
         * Deliberately the SAME accessible name the real image would carry, so
         * the name does not change depending on whether artwork loaded. A screen
         * reader user gets "Poster for Alpha" either way; only the glyph differs,
         * and that is decorative.
         */
        aria-label={alt}
      >
        <span aria-hidden="true">◉</span>
      </div>
    );
  }

  return (
    <img
      src={src}
      alt={alt}
      width={POSTER_WIDTH}
      height={POSTER_HEIGHT}
      onError={() => setFailed(true)}
      {...(priority === 'lcp' ? { fetchPriority: 'high' as const } : {})}
      {...(priority === 'lazy' ? { loading: 'lazy' as const } : {})}
      className="h-full w-full object-cover"
    />
  );
}