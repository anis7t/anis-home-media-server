import { useCallback, useEffect, useState } from 'react';
import { NavLink, useLocation } from 'react-router';
import type { ReactNode } from 'react';

import { useAuth } from '../auth/AuthProvider';
import Avatar from '../components/Avatar';
import LoginScreen from '../components/LoginScreen';

function BrandMark() {
  return (
    <svg viewBox="0 0 36 36" fill="none" className="h-9 w-9" aria-hidden="true">
      <defs>
        <linearGradient id="webBrandGrad" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" stopColor="#ff334b" />
          <stop offset="45%" stopColor="#e50914" />
          <stop offset="100%" stopColor="#990014" />
        </linearGradient>
      </defs>
      <rect width="36" height="36" rx="9" fill="#141822" />
      <rect x="0.5" y="0.5" width="35" height="35" rx="8.5" stroke="rgba(255,255,255,0.08)" />
      <path
        d="M12 9.2C10.7 8.4 9 9.3 9 10.9v14.2c0 1.6 1.7 2.5 3 1.7l13.5-7.1c1.3-.8 1.3-2.6 0-3.4L12 9.2z"
        fill="url(#webBrandGrad)"
      />
    </svg>
  );
}

export function AppShell({ children }: { children: ReactNode }) {
  const { authenticated, email, name, locked, signIn, signOut } = useAuth();
  const location = useLocation();

  /*
   * The sign-in screen appears only when the server has actually REFUSED this
   * client, not merely because nobody is signed in. Enforcement can be off
   * while authentication is still perfectly possible, and showing a locked
   * screen then would be wrong - the app is usable.
   */
  const showLogin = locked && !authenticated;

  const [menuOpen, setMenuOpen] = useState(false);

  /* Close the dropdown when anything outside is clicked. */
  useEffect(() => {
    if (!menuOpen) return;
    const onOutside = () => setMenuOpen(false);
    window.addEventListener('click', onOutside);
    return () => window.removeEventListener('click', onOutside);
  }, [menuOpen]);

  const stop = useCallback(() => setMenuOpen(false), []);

  return (
    <div className="min-h-screen">
      <header className="glass-header sticky top-0 z-20">
        <div className="mx-auto flex max-w-[1600px] items-center gap-6 px-4 py-3 sm:px-6">
          <NavLink to="/" className="flex items-center gap-3">
            <BrandMark />
            <span className="hidden sm:block">
              <span className="block text-sm font-bold text-white">
                <span className="text-brand-400">Anis&apos;</span> Home Media Server
              </span>
              <span className="block text-[10px] tracking-[0.2em] text-white/40">
                PLAY • ORGANIZE • ENJOY
              </span>
            </span>
          </NavLink>

          <nav className="ml-auto flex items-center gap-1" aria-label="Primary">
            <NavLink
              to="/"
              end
              className={({ isActive }) =>
                `rounded-full px-4 py-2 text-sm transition ${
                  isActive
                    ? 'bg-white/10 font-semibold text-white'
                    : 'text-white/60 hover:bg-white/5 hover:text-white'
                }`
              }
            >
              Library
            </NavLink>

            {/* Hidden on the player, where a stray nav click would interrupt playback. */}
            {location.pathname.startsWith('/watch/') ? null : authenticated ? (
              <div className="relative">
                <button
                  type="button"
                  onClick={() => setMenuOpen((v) => !v)}
                  aria-haspopup="menu"
                  aria-expanded={menuOpen}
                  aria-label="Open account menu"
                  className="card-ring flex h-9 w-9 items-center justify-center rounded-full overflow-hidden border border-white/15 transition hover:border-white/30 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-400"
                  onMouseEnter={stop}
                  onMouseLeave={stop}
                  onFocus={stop}
                  onBlur={stop}
                >
                  <Avatar size="md" label={name ?? 'User'} />
                </button>

                {menuOpen && (
                  <div
                    role="menu"
                    className="absolute right-0 z-30 mt-2 w-64 overflow-hidden rounded-xl border border-white/15 bg-obsidian-800 shadow-xl"
                    onMouseEnter={stop}
                    onMouseLeave={stop}
                    onFocus={stop}
                    onBlur={stop}
                  >
                    <div className="border-b border-white/10 px-4 py-3">
                      <div className="flex items-center gap-3">
                        <Avatar size="sm" label={name ?? 'User'} />
                        <div className="min-w-0">
                          <p className="truncate text-sm font-semibold text-white">
                            {name ?? 'Account'}
                          </p>
                          <p className="truncate text-xs text-white/50">{email}</p>
                        </div>
                      </div>
                    </div>
                    <div className="px-2 py-1" onClick={stop}>
                      <NavLink
                        to="/account"
                        className={({ isActive }) =>
                          `flex items-center gap-2 rounded-lg px-3 py-2 text-sm transition ${
                            isActive
                              ? 'bg-brand-500/20 text-brand-300'
                              : 'text-white/80 hover:bg-white/5 hover:text-white'
                          }`
                        }
                      >
                        Device tokens & settings
                      </NavLink>
                    </div>
                    <div className="border-t border-white/10 px-2 py-1">
                      <button
                        type="button"
                        onClick={signOut}
                        className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-sm text-white/70 transition hover:bg-white/5 hover:text-white"
                        onMouseEnter={stop}
                        onMouseLeave={stop}
                        onFocus={stop}
                        onBlur={stop}
                      >
                        Sign out
                      </button>
                    </div>
                  </div>
                )}
              </div>
            ) : (
              <button
                type="button"
                onClick={signIn}
                className="card-ring rounded-full bg-white/10 px-4 py-2 text-sm font-semibold text-white hover:bg-white/15"
              >
                Sign in
              </button>
            )}
          </nav>
        </div>
      </header>

      <main className="mx-auto max-w-[1600px] px-4 py-8 sm:px-6">
        {showLogin ? <LoginScreen /> : children}
      </main>
    </div>
  );
}

export default AppShell;