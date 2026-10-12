import { useCallback, useEffect, useRef, useState } from 'react';
import { Icon } from '../../components/icons';

export interface CastMember {
  readonly name: string;
  readonly character?: string;
  readonly profile_path?: string;
}

const PROFILE_BASE = 'https://image.tmdb.org/t/p/w185';

function profileUrl(profilePath: string | undefined): string | null {
  if (!profilePath || !profilePath.startsWith('/')) return null;
  return `${PROFILE_BASE}${profilePath}`;
}

/**
 * Initials for the fallback tile: two letters where a first and last name
 * exist, otherwise the first one. "Keir Dullea" -> "KD", "Cher" -> "C".
 */
function initials(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return '?';
  if (parts.length === 1) return parts[0].slice(0, 1).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

interface CastRailProps {
  readonly cast: readonly CastMember[];
  readonly limit?: number;
}

/**
 * Top-billed cast as a horizontal rail.
 *
 * The rail is a real scroll container rather than a clipped row, so every
 * credit stays reachable by keyboard, by touch swipe, and by scrollbar. Native
 * scrolling is preferred over a JS-driven carousel: it keeps momentum on
 * trackpads and needs no lifecycle to stay correct.
 *
 * `content-visibility: auto` lets the browser skip layout and paint for tiles
 * scrolled out of view, which matters because TMDb lists up to ~20.
 */
export function CastRail({ cast, limit = 18 }: CastRailProps) {
  const [broken, setBroken] = useState<ReadonlySet<number>>(() => new Set());
  const railRef = useRef<HTMLUListElement>(null);

  /*
   * The edge fades are a scroll affordance, so they may appear only when the
   * rail can actually scroll. A pure-CSS scroll-timeline cannot express "is
   * scrollable": with nothing to scroll, the timeline is inactive and the base
   * mask would still paint a fade that promises content which is not there.
   * Measuring overflow is therefore the difference between a correct hint and
   * a lie. A ResizeObserver keeps it honest as tiles and portraits arrive.
   *
   * `atStart`/`atEnd` drive the arrow buttons: a disabled arrow is the honest
   * signal that there is nothing further that way, so it is measured too
   * rather than assumed from scroll position alone.
   */
  const [edges, setEdges] = useState({ scrollable: false, atStart: true, atEnd: false });
  const measure = useCallback(() => {
    const node = railRef.current;
    if (!node) return;
    const maxScroll = node.scrollWidth - node.clientWidth;
    setEdges({
      scrollable: maxScroll > 1,
      atStart: node.scrollLeft <= 1,
      atEnd: node.scrollLeft >= maxScroll - 1,
    });
  }, []);

  useEffect(() => {
    measure();

    const node = railRef.current;
    if (!node) return;
    // Re-measure on scroll so the arrows disable at each end, and on resize so
    // the edge states survive a layout change.
    node.addEventListener('scroll', measure, { passive: true });

    let observer: ResizeObserver | undefined;
    if (typeof ResizeObserver !== 'undefined') {
      observer = new ResizeObserver(measure);
      observer.observe(node);
    }

    return () => {
      node.removeEventListener('scroll', measure);
      observer?.disconnect();
    };
  }, [cast, measure]);

  /** Scroll by roughly one card plus its gap, so a click always lands on a tile edge. */
  const nudge = (direction: -1 | 1) => {
    const node = railRef.current;
    if (!node) return;
    const card = node.querySelector('li');
    const step = card ? card.getBoundingClientRect().width + 16 : node.clientWidth * 0.8;
    node.scrollBy({ left: direction * step, behavior: 'smooth' });
  };

  const members = cast.slice(0, limit);
  if (members.length === 0) return null;

  const markBroken = (index: number) => {
    setBroken((prev) => (prev.has(index) ? prev : new Set(prev).add(index)));
  };

  return (
    <div className="cast-rail-wrap group/rail relative">
      {/*
        Arrow controls replace the native scrollbar, which read as a raw
        scrollbar and broke the page's visual language. They are only rendered
        when the rail overflows, and each is disabled at its own end so it never
        offers a scroll that would do nothing.
      */}
      {edges.scrollable ? (
        <>
          <RailButton
            side="left"
            disabled={edges.atStart}
            onClick={() => nudge(-1)}
          />
          <RailButton side="right" disabled={edges.atEnd} onClick={() => nudge(1)} />
        </>
      ) : null}

      <ul
        ref={railRef}
        className="cast-rail -mr-4 flex snap-x snap-mandatory gap-4 overflow-x-auto pr-4 sm:-mr-6 sm:pr-6"
        aria-label="Top billed cast"
        data-scrollable={edges.scrollable ? 'true' : 'false'}
      >
        {members.map((member, index) => {
          const src = broken.has(index) ? null : profileUrl(member.profile_path);
          return (
            <li
              key={`${member.name}-${index}`}
              className="w-[92px] shrink-0 snap-start [content-visibility:auto] [contain-intrinsic-size:auto_138px]"
            >
              <div className="mb-2 aspect-2/3 overflow-hidden rounded-xl border border-white/10 bg-obsidian-800 shadow-lg shadow-black/40">
                {src ? (
                  <img
                  src={src}
                  alt={member.name}
                  width={185}
                  height={278}
                  loading="lazy"
                  decoding="async"
                  onError={() => markBroken(index)}
                  className="h-full w-full object-cover"
                />
              ) : (
                <div
                  className="flex h-full w-full items-center justify-center bg-gradient-to-b from-white/12 to-white/5 text-lg font-semibold text-white/70"
                  aria-label={member.name}
                  role="img"
                >
                  <span aria-hidden="true">{initials(member.name)}</span>
                </div>
              )}
            </div>
            <p className="truncate text-xs font-medium text-white/90" title={member.name}>
              {member.name}
            </p>
            {member.character ? (
              <p
                className="mt-0.5 flex items-start gap-1 text-[11px] leading-tight text-white/45"
                title={member.character}
              >
                <Icon name="user" size={11} className="mt-[1px] opacity-70" />
                <span className="line-clamp-2">{member.character}</span>
              </p>
            ) : null}
          </li>
          );
        })}
      </ul>
    </div>
  );
}

/**
 * Circular scroll control for one edge of the rail.
 *
 * Sits over the rail on a solid surface so it stays legible against whatever
 * artwork passes beneath it. Opacity is driven by `group-hover/rail` so the
 * controls stay out of the way until the pointer is near, but they are never
 * `opacity-0` with `pointer-events` removed: a control that only exists on
 * hover cannot be reached by keyboard, so it fades visually instead.
 */
function RailButton({
  side,
  disabled,
  onClick,
}: {
  side: 'left' | 'right';
  disabled: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      aria-label={side === 'left' ? 'Scroll cast left' : 'Scroll cast right'}
      className={`absolute top-[38%] z-10 flex h-9 w-9 -translate-y-1/2 items-center justify-center rounded-full border border-white/15 bg-obsidian-900/85 text-white/90 shadow-lg shadow-black/50 backdrop-blur transition hover:bg-obsidian-800 hover:text-white disabled:pointer-events-none disabled:opacity-0 ${
        side === 'left'
          ? 'left-1 opacity-0 transition-opacity group-hover/rail:opacity-100 focus-visible:opacity-100'
          : 'right-1 opacity-0 transition-opacity group-hover/rail:opacity-100 focus-visible:opacity-100'
      }`}
    >
      <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth={2}
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
        focusable="false"
        className={`h-4 w-4 ${side === 'left' ? 'rotate-180' : ''}`}
      >
        <path d="M9 5l7 7-7 7" />
      </svg>
    </button>
  );
}