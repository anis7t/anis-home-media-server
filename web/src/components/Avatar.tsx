import { useAuth } from '../auth/AuthProvider';

export interface AvatarProps {
  /** Small (menu) or medium (header trigger) sizing. */
  size?: 'sm' | 'md';
  /** Optional explicit text to derive an initial from, overriding the icon. */
  fallback?: string;
  /** Optional aria label for screen readers. */
  label?: string;
}

/**
 * Avatar for a signed-in user.
 *
 * Precedence: the Google picture when there is one, otherwise a person
 * silhouette. A silhouette is the universally understood "account" affordance —
 * a bare letter inside an unstyled circle reads as a label rather than as a
 * button, which is what made the header trigger hard to recognise.
 */
export function Avatar({ size = 'md', fallback, label }: AvatarProps) {
  const { name, picture, email } = useAuth();
  const accessibleLabel = label ?? name ?? email ?? 'Your account';

  if (picture) {
    return (
      <img
        src={picture}
        alt={accessibleLabel}
        className={frameClass(size)}
        loading="lazy"
        referrerPolicy="no-referrer"
      />
    );
  }

  // An explicit `fallback` still wins, so callers that know the display name
  // can ask for initials explicitly.
  if (fallback) {
    return (
      <span
        className={frameClass(size) + ' ' + plateClass(size)}
        aria-label={accessibleLabel}
        role="img"
      >
        {fallback[0].toUpperCase()}
      </span>
    );
  }

  return (
    <span
      className={frameClass(size) + ' ' + plateClass(size)}
      aria-label={accessibleLabel}
      role="img"
    >
      <PersonGlyph size={size} />
    </span>
  );
}

/** Human glyph: head + shoulders. Decorative; the label carries the meaning. */
function PersonGlyph({ size }: { size: 'sm' | 'md' }) {
  const box = size === 'sm' ? 'h-4 w-4' : 'h-[18px] w-[18px]';
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={box}
      aria-hidden="true"
      focusable="false"
    >
      <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2" />
      <circle cx="12" cy="7" r="4" />
    </svg>
  );
}

/** The circular frame. `rounded-full` is required on the image path too,
 *  because the menu avatar is not inside the clipping header button. */
function frameClass(size: 'sm' | 'md'): string {
  return (
    'shrink-0 rounded-full object-cover ' +
    (size === 'sm' ? 'h-7 w-7' : 'h-9 w-9')
  );
}

/** Subtle raised plate so the control reads as a button, not a glyph. */
function plateClass(size: 'sm' | 'md'): string {
  return (
    'flex items-center justify-center border border-white/15 bg-white/10 ' +
    'text-white/90 ' +
    (size === 'sm' ? '' : 'group-hover:bg-white/15 ')
  );
}

export default Avatar;