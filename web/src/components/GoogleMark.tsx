interface GoogleMarkProps {
  /** Tailwind sizing classes for the glyph. */
  readonly className?: string;
}

/**
 * The Google "G" mark used by the sign-in surfaces.
 *
 * Decorative: the surrounding button text carries the meaning, so the SVG is
 * hidden from assistive technology.
 */
export function GoogleMark({ className = 'h-5 w-5' }: GoogleMarkProps) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden="true">
      <path
        fill="#4285F4"
        d="M23.49 12.27c0-.79-.07-1.54-.19-2.27H12v4.51h6.47a5.4 5.4 0 0 1-2.4 3.58v2.77h3.86c2.26-2.09 3.56-5.17 3.56-8.59z"
      />
      <path
        fill="#34A853"
        d="M12 24c3.24 0 5.96-1.08 7.94-2.91l-3.86-2.77c-1.08.72-2.45 1.16-4.08 1.16-3.13 0-5.78-2.11-6.73-4.96H1.29v3.09A12 12 0 0 0 12 24z"
      />
      <path
        fill="#FBBC05"
        d="M5.27 14.52a7.2 7.2 0 0 1 0-4.6V6.83H1.29a12 12 0 0 0 0 10.79l3.98-3.1z"
      />
      <path
        fill="#EA4335"
        d="M12 4.75c1.77 0 3.35.61 4.6 1.8l3.43-3.43C17.95 1.19 15.24 0 12 0A12 12 0 0 0 1.29 6.83l3.98 3.09C6.22 6.86 8.87 4.75 12 4.75z"
      />
    </svg>
  );
}
