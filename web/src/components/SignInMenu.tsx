import { useEffect, useId, useRef, useState } from 'react';
import { Link } from 'react-router';

import { Icon } from './icons';
import { GoogleMark } from './GoogleMark';

export interface SignInMenuProps {
  /** Whether the server has Google OAuth configured. */
  readonly oauthConfigured: boolean;
  /** Starts the existing Google OAuth redirect. */
  readonly onGoogleSignIn: () => void;
  /** Opens the existing Admin PIN modal. */
  readonly onPinSignIn: () => void;
}

const MENU_ITEM_CLASS =
  'flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-left transition hover:bg-white/5 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-400';

const ICON_WRAPPER_CLASS =
  'flex h-8 w-8 shrink-0 items-center justify-center rounded-xl border border-white/10 bg-white/5';

/**
 * The signed-out header's sign-in chooser.
 *
 * The QR entry is a link to `/account`, where the existing `QrSignInPanel`
 * owns the session lifecycle. Opening this menu deliberately creates no QR
 * session: a pair session is only minted when the account page mounts.
 *
 * The component is rendered only on non-phone browsers. A phone is the device
 * that scans the QR, so its header keeps the direct Google button instead of
 * offering a QR code to itself.
 */
export function SignInMenu({
  oauthConfigured,
  onGoogleSignIn,
  onPinSignIn,
}: SignInMenuProps) {
  const [open, setOpen] = useState(false);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const menuId = useId();

  useEffect(() => {
    if (!open) return;

    const menu = menuRef.current;
    if (!menu) return;

    const items = () =>
      Array.from(menu.querySelectorAll<HTMLElement>('[role="menuitem"]'));

    // Focus the first action so a remote's D-pad can drive the menu without
    // first tabbing through the rest of the header.
    items()[0]?.focus();

    const onPointerDown = (event: PointerEvent) => {
      const target = event.target as Node;
      if (triggerRef.current?.contains(target)) return;
      if (menuRef.current?.contains(target)) return;
      setOpen(false);
    };

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        setOpen(false);
        triggerRef.current?.focus();
        return;
      }

      if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return;

      const menuItems = items();
      if (menuItems.length === 0) return;

      event.preventDefault();
      const current = menuItems.indexOf(document.activeElement as HTMLElement);
      let next = 0;

      if (event.key === 'ArrowDown') {
        next = current < 0 ? 0 : (current + 1) % menuItems.length;
      } else if (event.key === 'ArrowUp') {
        next = current <= 0 ? menuItems.length - 1 : current - 1;
      } else if (event.key === 'End') {
        next = menuItems.length - 1;
      }

      menuItems[next]?.focus();
    };

    // Tab out of the menu closes it, but Tab itself is not prevented.
    const onFocusIn = (event: FocusEvent) => {
      const target = event.target as Node;
      if (triggerRef.current?.contains(target)) return;
      if (menuRef.current?.contains(target)) return;
      setOpen(false);
    };

    document.addEventListener('pointerdown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    document.addEventListener('focusin', onFocusIn);

    return () => {
      document.removeEventListener('pointerdown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
      document.removeEventListener('focusin', onFocusIn);
    };
  }, [open]);

  const closeAndSignIn = (action: () => void) => {
    setOpen(false);
    action();
  };

  return (
    <div className="relative">
      <button
        ref={triggerRef}
        type="button"
        onClick={() => setOpen((value) => !value)}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={menuId}
        title="Sign in options"
        className="card-ring inline-flex items-center gap-1.5 rounded-full bg-brand-500 px-4 py-2 text-sm font-semibold text-white shadow-sm transition-colors hover:bg-brand-600 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-400"
      >
        <span>Sign in</span>
        <Icon
          name="chevron"
          size={14}
          className={`transition-transform duration-200 ${open ? 'rotate-180' : ''}`}
        />
      </button>

      {open && (
        <div
          ref={menuRef}
          id={menuId}
          role="menu"
          aria-label="Sign in options"
          aria-orientation="vertical"
          className="absolute right-0 z-30 mt-2 w-72 max-w-[calc(100vw-1.5rem)] overflow-hidden rounded-2xl border border-white/15 bg-obsidian-850 shadow-2xl backdrop-blur-xl animate-fade-in"
        >
          <div className="border-b border-white/10 bg-white/[0.02] px-4 py-3">
            <p className="text-sm font-semibold text-white">Sign in</p>
            <p className="mt-0.5 text-xs text-white/50">
              {oauthConfigured
                ? 'Choose how to continue'
                : 'Google sign-in is not configured'}
            </p>
          </div>

          <div className="space-y-1 px-2 py-2">
            {oauthConfigured ? (
              <button
                type="button"
                role="menuitem"
                onClick={() => closeAndSignIn(onGoogleSignIn)}
                className={MENU_ITEM_CLASS}
              >
                <span className={ICON_WRAPPER_CLASS}>
                  <GoogleMark className="h-4 w-4" />
                </span>
                <span className="min-w-0">
                  <span className="block text-sm font-medium text-white">
                    Continue with Google
                  </span>
                  <span className="block text-[11px] text-white/45">
                    Use your Google account
                  </span>
                </span>
              </button>
            ) : (
              <button
                type="button"
                role="menuitem"
                onClick={() => closeAndSignIn(onPinSignIn)}
                className={MENU_ITEM_CLASS}
              >
                <span className={ICON_WRAPPER_CLASS}>
                  <Icon name="shield" size={16} className="text-amber-400" />
                </span>
                <span className="min-w-0">
                  <span className="block text-sm font-medium text-white">
                    Sign in with Admin PIN
                  </span>
                  <span className="block text-[11px] text-white/45">
                    Local recovery access
                  </span>
                </span>
              </button>
            )}

            <Link
              to="/account"
              role="menuitem"
              onClick={() => setOpen(false)}
              className={MENU_ITEM_CLASS}
            >
              <span className={ICON_WRAPPER_CLASS}>
                <Icon name="qr" size={16} className="text-sky-400" />
              </span>
              <span className="min-w-0">
                <span className="block text-sm font-medium text-white">
                  Sign in with QR code
                </span>
                <span className="block text-[11px] text-white/45">
                  Use your phone to scan
                </span>
              </span>
            </Link>
          </div>
        </div>
      )}
    </div>
  );
}

export default SignInMenu;
