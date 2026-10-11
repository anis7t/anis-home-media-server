import { useAuth } from '../auth/AuthProvider';

export interface AvatarProps {
  /** Small (20px) or medium (32px) sizing. */
  size?: 'sm' | 'md';
  /** Text shown when no picture is available. */
  fallback?: string;
  /** Optional aria label for screen readers. */
  label?: string;
}

/**
 * Avatar for a signed-in user. Shows the Google picture when present,
 * otherwise a monochrome initial from the account name.
 */
export function Avatar({ size = 'md', fallback, label }: AvatarProps) {
  const { name, picture } = useAuth();

  if (picture) {
    return (
      <img
        src={picture}
        alt={label ?? (name ?? 'User')}
        className={sizeClass(size)}
        loading="lazy"
      />
    );
  }

  const initial = (fallback ?? (name ?? 'U'))[0].toUpperCase();
  return (
    <div
      className={sizeClass(size) + ' avatar-initial flex items-center justify-center rounded-full bg-white/15 font-semibold text-white'}
      aria-label={label ?? (name ?? 'User')}
      role="img"
    >
      {initial}
    </div>
  );
}

function sizeClass(size: 'sm' | 'md'): string {
  return size === 'sm'
    ? 'h-5 w-5 text-xs'
    : 'h-9 w-9 text-base';
}

export default Avatar;