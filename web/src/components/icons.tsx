/**
 * Inline SVG icon set for the details experience.
 *
 * Inline rather than an icon package: these are ~16 stroke paths, and shipping a
 * dependency to draw them would be the larger cost. Every glyph is
 * `currentColor` and inherits sizing from the caller, so an icon is never a
 * second source of truth for colour.
 *
 * Accessibility contract: icons here are **decorative**. Each is `aria-hidden`
 * because the surrounding text or the control's accessible name already
 * carries the meaning. Never rely on an icon alone to convey state.
 */

export type IconName =
  | 'play'
  | 'rotate'
  | 'star'
  | 'clock'
  | 'calendar'
  | 'ticket'
  | 'video'
  | 'audio'
  | 'speakers'
  | 'disc'
  | 'subtitles'
  | 'gauge'
  | 'ruler'
  | 'users'
  | 'clapper'
  | 'pen'
  | 'building'
  | 'user'
  | 'external'
  | 'youtube'
  | 'check'
  | 'chevron'
  | 'bolt'
  | 'sparkle'
  | 'film'
  | 'search'
  | 'x'
  | 'filter'
  | 'sort'
  | 'arrow-left'
  | 'arrow-right'
  | 'info'
  | 'refresh'
  | 'download'
  | 'folder'
  | 'trash'
  | 'archive'
  | 'devices'
  | 'book'
  | 'shield'
  | 'cast'
  | 'tv';

const PATHS: Record<IconName, React.ReactElement> = {
  trash: (
    <>
      <path d="M3 6h18M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2M10 11v6M14 11v6" />
    </>
  ),
  archive: (
    <>
      <rect width="20" height="5" x="2" y="3" rx="1" />
      <path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8M10 12h4" />
    </>
  ),
  search: (
    <>
      <circle cx="11" cy="11" r="7" />
      <path d="m20 20-4.35-4.35" />
    </>
  ),
  x: <path d="M18 6 6 18M6 6l12 12" />,
  filter: (
    <>
      <polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3" />
    </>
  ),
  sort: (
    <>
      <path d="m3 16 4 4 4-4M7 20V4M21 8l-4-4-4 4M17 4v16" />
    </>
  ),
  'arrow-left': <path d="m15 18-6-6 6-6" />,
  'arrow-right': <path d="m9 18 6-6-6-6" />,
  info: (
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 16v-4M12 8h.01" />
    </>
  ),
  play: <path d="M6 4.5v15l13-7.5-13-7.5Z" fill="currentColor" stroke="none" />,
  rotate: (
    <>
      <path d="M3 12a9 9 0 1 0 3-6.7" />
      <path d="M3 4v5h5" />
    </>
  ),
  star: (
    <path
      d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.9-5.2-2.8-5.2 2.8 1-5.9L3.5 9.7l5.9-.8L12 3.5Z"
      fill="currentColor"
      stroke="none"
    />
  ),
  clock: (
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 7v5.2l3.2 2" />
    </>
  ),
  calendar: (
    <>
      <rect x="3.5" y="5" width="17" height="16" rx="2.5" />
      <path d="M3.5 10h17M8.5 3v4M15.5 3v4" />
    </>
  ),
  ticket: (
    <>
      <path d="M3 9.5V7a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v2.5a2.5 2.5 0 0 0 0 7V19a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-2.5a2.5 2.5 0 0 0 0-7Z" />
      <path d="M14 5v14" strokeDasharray="2 3" />
    </>
  ),
  video: (
    <>
      <rect x="3" y="6" width="13" height="12" rx="2.5" />
      <path d="M16 10.5l4.2-2.6a.6.6 0 0 1 .9.5v7.2a.6.6 0 0 1-.9.5L16 13.5" />
    </>
  ),
  audio: (
    <>
      <path d="M4 15V9.5a3.5 3.5 0 0 1 7 0V15" />
      <rect x="2.6" y="13.4" width="3.4" height="6.2" rx="1.7" />
      <rect x="8.9" y="13.4" width="3.4" height="6.2" rx="1.7" />
      <path d="M15.5 5.2a7 7 0 0 1 5 4.3M15.5 18.8a7 7 0 0 0 5-4.3" />
    </>
  ),
  speakers: (
    <>
      <rect x="4" y="3.5" width="16" height="7" rx="2" />
      <rect x="4" y="13.5" width="16" height="7" rx="2" />
      <path d="M7.5 7h.01M7.5 17h.01" />
    </>
  ),
  disc: (
    <>
      <circle cx="12" cy="12" r="9" />
      <circle cx="12" cy="12" r="2.6" />
      <path d="M12 3v6.4" />
    </>
  ),
  subtitles: (
    <>
      <rect x="3" y="5" width="18" height="14" rx="2.5" />
      <path d="M6.5 14.5h4M13.5 14.5h4M6.5 10.5h2M11 10.5h2M15.5 10.5h2" />
    </>
  ),
  gauge: (
    <>
      <path d="M4 17a8.5 8.5 0 1 1 16 0" />
      <path d="M12 17l3.6-4.6" />
      <circle cx="12" cy="17" r="1.1" fill="currentColor" stroke="none" />
    </>
  ),
  ruler: (
    <>
      <rect x="2.6" y="8.6" width="18.8" height="6.8" rx="1.8" />
      <path d="M7 8.6v2.6M11 8.6v3.4M15 8.6v2.6M19 8.6v3.4" />
    </>
  ),
  users: (
    <>
      <circle cx="9.5" cy="8.5" r="3.5" />
      <path d="M3.5 20a6 6 0 0 1 12 0" />
      <path d="M16.5 5.6a3.5 3.5 0 0 1 0 6.6M17.5 14.6A6 6 0 0 1 20.5 20" />
    </>
  ),
  clapper: (
    <>
      <path d="M3 8.5h18v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-10Z" />
      <path d="M3 8.5 4.8 4.6a1 1 0 0 1 .86-.5H20l-1.2 4.4" />
      <path d="M7.5 4.2 8.8 8.5M12 4.2l-1.3 4.3M16.5 4.2l-1.3 4.3" />
    </>
  ),
  pen: (
    <>
      <path d="M4 20.5h4L20 8.5a2.1 2.1 0 0 0-3-3L5 17.5v3Z" />
      <path d="M14.5 6.5l3 3" />
    </>
  ),
  building: (
    <>
      <path d="M4 21V5.5A1.5 1.5 0 0 1 5.5 4h8A1.5 1.5 0 0 1 15 5.5V21" />
      <path d="M15 10h3.5A1.5 1.5 0 0 1 20 11.5V21M3 21h18" />
      <path d="M7.5 8h4M7.5 12h4M7.5 16h4" />
    </>
  ),
  user: (
    <>
      <circle cx="12" cy="8" r="4" />
      <path d="M4.5 21a7.5 7.5 0 0 1 15 0" />
    </>
  ),
  external: (
    <>
      <path d="M14 4h6v6" />
      <path d="M20 4l-8.5 8.5" />
      <path d="M18 14.5V19a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4.5" />
    </>
  ),
  youtube: (
    <>
      <rect x="2.5" y="5.5" width="19" height="13" rx="4" />
      <path d="M10.2 9.3l4.6 2.7-4.6 2.7V9.3Z" fill="currentColor" stroke="none" />
    </>
  ),
  check: <path d="M5 12.5l4.5 4.5L19 7.5" />,
  chevron: <path d="M6 9.5l6 6 6-6" />,
  bolt: <path d="M13.5 2.5 4.5 13.8h6L10.5 21.5 19.5 10.2h-6V2.5Z" />,
  sparkle: (
    <>
      <path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9L12 3Z" />
      <path d="M18.5 15.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8.8-2.2Z" />
    </>
  ),
  film: (
    <>
      <rect x="3" y="4.5" width="18" height="15" rx="2.5" />
      <path d="M8 4.5v15M16 4.5v15M3 12h18M3 8.2h5M3 15.8h5M16 8.2h5M16 15.8h5" />
    </>
  ),
  refresh: (
    <>
      <path d="M21 12a9 9 0 0 0-9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" />
      <path d="M3 3v5h5" />
      <path d="M3 12a9 9 0 0 0 9 9 9.75 9.75 0 0 0 6.74-2.74L21 16" />
      <path d="M16 16h5v5" />
    </>
  ),
  download: (
    <>
      <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
      <polyline points="7 10 12 15 17 10" />
      <line x1="12" y1="15" x2="12" y2="3" />
    </>
  ),
  folder: (
    <>
      <path d="M4 20h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.93a2 2 0 0 1-1.66-.9l-.82-1.2A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13c0 1.1.9 2 2 2Z" />
    </>
  ),
  devices: (
    <>
      <rect x="2" y="4" width="13" height="10" rx="2" />
      <path d="M5 18h7" />
      <path d="M8.5 14v4" />
      <rect x="14" y="9" width="8" height="12" rx="2" />
      <path d="M18 18h.01" />
    </>
  ),
  book: (
    <>
      <path d="M4 19.5v-15A2.5 2.5 0 0 1 6.5 2H20v20H6.5a2.5 2.5 0 0 1-2.5-2.5Z" />
      <path d="M6 6h10" />
      <path d="M6 10h10" />
    </>
  ),
  shield: (
    <>
      <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10Z" />
      <path d="m9 12 2 2 4-4" />
    </>
  ),
  cast: (
    <>
      <path d="M2 16.1A5 5 0 0 1 5.9 20" />
      <path d="M2 12.05A9 9 0 0 1 9.95 20" />
      <path d="M2 8V6a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-6" />
      <line x1="2" y1="20" x2="2.01" y2="20" strokeWidth={2.5} />
    </>
  ),
  tv: (
    <>
      <rect x="2" y="7" width="20" height="15" rx="2" ry="2" />
      <polyline points="17 2 12 7 7 2" />
    </>
  ),
};

interface IconProps {
  readonly name: IconName;
  /** Edge length in px. Defaults to 1em so it tracks the text it sits beside. */
  readonly size?: number;
  readonly className?: string;
}

export function Icon({ name, size, className = '' }: IconProps) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.7}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      {...(size ? { width: size, height: size } : {})}
      className={`${size ? 'shrink-0' : 'h-[1em] w-[1em] shrink-0'} ${className}`}
    >
      {PATHS[name]}
    </svg>
  );
}