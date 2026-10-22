import { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { NavLink, useLocation } from 'react-router';
import type { ReactNode } from 'react';

import { useAuth } from '../auth/AuthProvider';
import Avatar from '../components/Avatar';
import BrandIntroOverlay from '../components/brand/BrandIntroOverlay';
import { Icon } from '../components/icons';
import LoginScreen from '../components/LoginScreen';
import { useIntroSequence } from '../hooks/useIntroSequence';
import BrandMark from '../components/BrandMark';

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
  const [privacyOpen, setPrivacyOpen] = useState(false);

  const buttonRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);

  /* Close dropdown when clicked outside */
  useEffect(() => {
    const handleClick = (event: MouseEvent) => {
      if (!menuOpen) return;
      if (buttonRef.current && buttonRef.current.contains(event.target as Node)) return;
      if (menuRef.current && menuRef.current.contains(event.target as Node)) return;
      setMenuOpen(false);
    };
    window.addEventListener('click', handleClick);
    return () => window.removeEventListener('click', handleClick);
  }, [menuOpen]);

  /* Reset window scroll to top whenever navigation occurs */
  useEffect(() => {
    window.scrollTo({ top: 0, left: 0, behavior: 'instant' as ScrollBehavior });
  }, [location.pathname]);

  /* Live active transcode count polling for compact header beacon */
  const [activeTranscodeCount, setActiveTranscodeCount] = useState<number>(0);
  useEffect(() => {
    let mounted = true;
    const checkTranscodes = async () => {
      try {
        const res = await fetch('/api/transcodes');
        if (res.ok) {
          const body = await res.json();
          if (mounted && Array.isArray(body.transcodes)) {
            setActiveTranscodeCount(body.transcodes.length);
          }
        }
      } catch {
        // tolerate network blip
      }
    };
    void checkTranscodes();
    const interval = setInterval(checkTranscodes, 3500);
    return () => {
      mounted = false;
      clearInterval(interval);
    };
  }, []);


  /*
   * The brand opening sequence.
   *
   * The hook is called BEFORE the `/remotelogin` early return, because a hook
   * must be called in the same order on every render.
   *
   * The overlay is mounted as a SIBLING of the page content, not a child of
   * it, so that it plays over the login screen (decision D5) rather than
   * inside it. The component portals itself to `document.body` and sits above
   * the `z-20` sticky header.
   *
   * The `/remotelogin` route returns below and never renders the overlay -
   * that page is a focused, single-purpose screen.
   *
   * The session gate is the CONTAINER's: `useIntroSequence` decides whether
   * to mount this at all and records that it has been seen. The overlay
   * itself never touches `sessionStorage`.
   */
  const intro = useIntroSequence();

  if (location.pathname === '/remotelogin') {
    return <main className="min-h-screen w-full">{children}</main>;
  }

  return (
    <div className="min-h-screen">
      {intro.shouldMount ? (
        <BrandIntroOverlay mode={intro.mode} onStarted={intro.onStarted} onFinished={intro.onFinished} />
      ) : null}

      {/* Sticky Obsidian Header */}
      <header className="glass-header app-header sticky top-0 z-20">
        <div className="app-header-surface mx-auto flex max-w-[1600px] items-center gap-3 sm:gap-6 px-3 py-3 transition-[background-color,box-shadow] duration-200 sm:px-6">
          <NavLink to="/" className="group flex items-center gap-3 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-400 rounded-lg p-1">
            <div className="transition-transform duration-300 group-hover:scale-105">
              <BrandMark className="h-9 w-9" />
            </div>
            <span className="hidden sm:block">
              <span className="block text-sm font-bold text-white transition-colors duration-200 group-hover:text-white">
                <span className="text-brand-400">Anis&apos;</span> Home Media Server
              </span>
              <span className="block text-[10px] tracking-[0.2em] text-white/40">
                PLAY • ORGANIZE • ENJOY
              </span>
            </span>
          </NavLink>

          {/* Live System Indicator */}
          <div className="hidden lg:flex items-center gap-2 rounded-full border border-emerald-500/25 bg-emerald-500/10 px-3 py-1 text-xs text-emerald-400 shadow-sm">
            <span className="relative flex h-2 w-2">
              <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-75"></span>
              <span className="relative inline-flex h-2 w-2 rounded-full bg-emerald-500"></span>
            </span>
            <span className="font-semibold tracking-wider text-[11px]">ONLINE</span>
          </div>

          <nav className="ml-auto flex items-center gap-1.5 sm:gap-2.5" aria-label="Primary">
            <NavLink
              to="/"
              end
              className={({ isActive }) =>
                `flex items-center gap-2 rounded-full px-3 sm:px-4 py-2 text-sm font-medium transition ${
                  isActive
                    ? 'bg-white/10 font-semibold text-white shadow-sm'
                    : 'text-white/60 hover:bg-white/5 hover:text-white'
                }`
              }
              title="Home Library"
            >
              <Icon name="film" className="text-brand-400" />
              <span className="hidden sm:inline">Library</span>
            </NavLink>

            {/* Glowing Active Transcode Indicator Pill */}
            {activeTranscodeCount > 0 ? (
              <NavLink
                to="/transcodes"
                className={({ isActive }) =>
                  `flex items-center gap-1.5 sm:gap-2 rounded-full border border-amber-500/30 bg-amber-500/15 px-3 py-1.5 text-xs font-semibold text-amber-300 shadow-sm transition active:scale-95 hover:bg-amber-500/25 ${
                    isActive ? 'ring-2 ring-amber-400 font-bold' : ''
                  }`
                }
                title="Active Transcodes Command Center"
              >
                <span className="relative flex h-2 w-2">
                  <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-amber-400 opacity-75"></span>
                  <span className="relative inline-flex rounded-full h-2 w-2 bg-amber-500"></span>
                </span>
                <Icon name="bolt" size={13} className="text-amber-400" />
                <span className="hidden sm:inline">
                  {activeTranscodeCount} {activeTranscodeCount === 1 ? 'Transcode' : 'Transcodes'}
                </span>
                <span className="sm:hidden">{activeTranscodeCount}</span>
              </NavLink>
            ) : null}



            {/* Get the App - Links to APK Distribution */}
            <NavLink
              to="/download"
              className={({ isActive }) =>
                `hidden md:flex items-center gap-2 rounded-full border border-white/10 px-3 sm:px-4 py-2 text-sm font-medium transition active:scale-95 ${
                  isActive
                    ? 'bg-white/10 font-semibold text-white shadow-sm border-white/20'
                    : 'bg-white/5 text-white/70 hover:bg-white/10 hover:text-white hover:border-white/20'
                }`
              }
              title="Download Android & Fire TV Client"
            >
              <Icon name="download" className="text-emerald-400" />
              <span className="hidden lg:inline">Get the app</span>
            </NavLink>

            {/* Manage Files & Storage */}
            <NavLink
              to="/manage"
              className={({ isActive }) =>
                `hidden lg:flex items-center gap-2 rounded-full border border-white/10 px-3.5 py-2 text-sm font-medium transition ${
                  isActive
                    ? 'bg-white/10 font-semibold text-white shadow-sm'
                    : 'bg-white/5 text-white/70 hover:bg-white/10 hover:text-white hover:border-white/20 active:scale-95'
                }`
              }
              title="Manage media files, storage pools & retention"
            >
              <Icon name="folder" className="text-amber-400" />
              <span>Manage</span>
            </NavLink>

            {/* TV & Mobile Devices */}
            <NavLink
              to="/account"
              className={({ isActive }) =>
                `hidden sm:flex items-center gap-2 rounded-full px-3 sm:px-4 py-2 text-sm font-medium transition ${
                  isActive
                    ? 'bg-white/10 font-semibold text-white shadow-sm'
                    : 'text-white/60 hover:bg-white/5 hover:text-white'
                }`
              }
              title="TV & Mobile device pairing"
            >
              <Icon name="devices" className="text-sky-400" />
              <span className="hidden xl:inline">Devices</span>
            </NavLink>

            {/* Hidden on the player, where a stray nav click would interrupt playback. */}
            {location.pathname.startsWith('/watch/') ? null : authenticated ? (
              <div className="relative">
                <button
                  ref={buttonRef}
                  type="button"
                  onClick={() => setMenuOpen((v) => !v)}
                  aria-haspopup="menu"
                  aria-expanded={menuOpen}
                  aria-label="Open account menu"
                  className="card-ring group flex h-9 w-9 items-center justify-center rounded-full border border-white/15 bg-white/5 shadow-sm transition hover:border-white/30 hover:bg-white/10 active:scale-95 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-400"
                >
                  <Avatar size="md" label={name ?? 'User'} />
                </button>

                {menuOpen && (
                  <div
                    ref={menuRef}
                    role="menu"
                    aria-orientation="vertical"
                    className="absolute right-0 z-30 mt-2 w-64 overflow-hidden rounded-2xl border border-white/15 bg-obsidian-850 shadow-2xl backdrop-blur-xl animate-fade-in"
                  >
                    <div className="border-b border-white/10 px-4 py-3 bg-white/[0.02]">
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
                    <div className="px-2 py-1.5 space-y-1">
                      <NavLink
                        to="/account"
                        onClick={() => setMenuOpen(false)}
                        className={({ isActive }) =>
                          `flex items-center gap-2.5 rounded-xl px-3 py-2 text-sm transition ${
                            isActive
                              ? 'bg-brand-500/20 text-brand-300 font-medium'
                              : 'text-white/80 hover:bg-white/5 hover:text-white'
                          }`
                        }
                      >
                        <Icon name="devices" className="text-sky-400" />
                        <span>TV &amp; Mobile Pairing</span>
                      </NavLink>
                      <NavLink
                        to="/manage"
                        onClick={() => setMenuOpen(false)}
                        className={({ isActive }) =>
                          `flex items-center gap-2.5 rounded-xl px-3 py-2 text-sm transition ${
                            isActive
                              ? 'bg-brand-500/20 text-brand-300 font-medium'
                              : 'text-white/80 hover:bg-white/5 hover:text-white'
                          }`
                        }
                      >
                        <Icon name="folder" className="text-amber-400" />
                        <span>Storage &amp; File Manager</span>
                      </NavLink>
                      <NavLink
                        to="/transcodes"
                        onClick={() => setMenuOpen(false)}
                        className={({ isActive }) =>
                          `flex items-center gap-2.5 rounded-xl px-3 py-2 text-sm transition ${
                            isActive
                              ? 'bg-brand-500/20 text-brand-300 font-medium'
                              : 'text-white/80 hover:bg-white/5 hover:text-white'
                          }`
                        }
                      >
                        <Icon name="bolt" className="text-amber-400" />
                        <span>Transcodes Dashboard</span>
                      </NavLink>
                      <NavLink
                        to="/devices"
                        onClick={() => setMenuOpen(false)}
                        className={({ isActive }) =>
                          `flex items-center gap-2.5 rounded-xl px-3 py-2 text-sm transition ${
                            isActive
                              ? 'bg-brand-500/20 text-brand-300 font-medium'
                              : 'text-white/80 hover:bg-white/5 hover:text-white'
                          }`
                        }
                      >
                        <Icon name="gauge" className="text-emerald-400" />
                        <span>Client Presence Telemetry</span>
                      </NavLink>
                      <NavLink
                        to="/manual"
                        onClick={() => setMenuOpen(false)}
                        className={({ isActive }) =>
                          `flex items-center gap-2.5 rounded-xl px-3 py-2 text-sm transition ${
                            isActive
                              ? 'bg-brand-500/20 text-brand-300 font-medium'
                              : 'text-white/80 hover:bg-white/5 hover:text-white'
                          }`
                        }
                      >
                        <Icon name="book" className="text-purple-400" />
                        <span>User Manual &amp; Shortcuts</span>
                      </NavLink>
                    </div>
                    <div className="border-t border-white/10 px-2 py-1.5">
                      <button
                        type="button"
                        onClick={() => {
                          setMenuOpen(false);
                          void signOut();
                        }}
                        className="flex w-full items-center gap-2.5 rounded-xl px-3 py-2 text-sm text-white/70 transition hover:bg-white/5 hover:text-white"
                      >
                        <Icon name="user" className="text-white/40" />
                        <span>Sign out</span>
                      </button>
                    </div>
                  </div>
                )}
              </div>
            ) : (
              <button
                type="button"
                onClick={signIn}
                className="card-ring rounded-full bg-brand-500 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-brand-600 transition-colors"
              >
                Sign in
              </button>
            )}
          </nav>
        </div>
      </header>

      {/* Main Container */}
      <main className="mx-auto max-w-[1600px] overflow-anchor-none px-4 py-8 sm:px-6">
        {showLogin ? <LoginScreen /> : children}
      </main>

      {/* Sleek Cinematic Obsidian Footer */}
      {!location.pathname.startsWith('/watch/') ? (
        <footer className="mt-20 border-t border-white/10 bg-obsidian-900/80 py-12 backdrop-blur-xl">
          <div className="mx-auto max-w-[1600px] px-4 sm:px-6 space-y-8">
            <div className="flex flex-col gap-6 lg:flex-row lg:items-center lg:justify-between text-center lg:text-left">
              {/* Brand Lockup */}
              <div className="flex flex-col items-center lg:items-start gap-1.5">
                <div className="flex items-center gap-2.5 text-base font-bold text-white">
                  <BrandMark className="h-9 w-9" />
                  <span>
                    <span className="text-brand-400">Anis&apos;</span> Home Media Server
                  </span>
                </div>
                <p className="text-xs text-white/50 tracking-wider">
                  PLAY • ORGANIZE • ENJOY — Private Cinema Engine
                </p>
              </div>

              {/* Hardware & Storage Badges */}
              <div className="flex flex-wrap items-center justify-center lg:justify-end gap-2.5 text-xs text-white/60">
                <span className="inline-flex items-center gap-1.5 rounded-full border border-white/10 bg-white/[0.04] px-3 py-1">
                  <Icon name="bolt" className="text-brand-400" />
                  Dual AMD Radeon RX 560X &amp; Vega 8
                </span>
                <span className="inline-flex items-center gap-1.5 rounded-full border border-white/10 bg-white/[0.04] px-3 py-1">
                  <Icon name="disc" className="text-sky-400" />
                  Storage Tiering (D: Flicks • E: SSD Engine)
                </span>
                <span className="rounded-full bg-emerald-500/10 border border-emerald-500/20 px-3 py-1 text-emerald-300 font-medium">
                  Rust · Axum API
                </span>
              </div>
            </div>

            {/* Quick Links Rail with Icons */}
            <div className="flex flex-wrap items-center justify-center gap-4 sm:gap-8 border-y border-white/5 py-4 text-xs font-medium text-white/70">
              <NavLink to="/" className="inline-flex items-center gap-1.5 hover:text-white transition-colors">
                <Icon name="film" className="text-brand-400" />
                <span>Library</span>
              </NavLink>
              <NavLink to="/manual" className="inline-flex items-center gap-1.5 hover:text-white transition-colors">
                <Icon name="book" className="text-purple-400" />
                <span>How to use</span>
              </NavLink>
              <NavLink to="/download" className="inline-flex items-center gap-1.5 hover:text-white transition-colors">
                <Icon name="download" className="text-emerald-400" />
                <span>Get the app</span>
              </NavLink>
              <NavLink to="/manage" className="inline-flex items-center gap-1.5 hover:text-white transition-colors">
                <Icon name="folder" className="text-amber-400" />
                <span>File Manager</span>
              </NavLink>
              <NavLink to="/transcodes" className="inline-flex items-center gap-1.5 hover:text-white transition-colors">
                <Icon name="bolt" className="text-amber-400" />
                <span>Transcodes</span>
              </NavLink>
              <NavLink to="/devices" className="inline-flex items-center gap-1.5 hover:text-white transition-colors">
                <Icon name="gauge" className="text-emerald-400" />
                <span>Devices Telemetry</span>
              </NavLink>
              <NavLink to="/account" className="inline-flex items-center gap-1.5 hover:text-white transition-colors">
                <Icon name="devices" className="text-sky-400" />
                <span>TV Pairing</span>
              </NavLink>
              <button
                type="button"
                onClick={() => setPrivacyOpen(true)}
                className="inline-flex items-center gap-1.5 hover:text-white transition-colors cursor-pointer"
              >
                <Icon name="shield" className="text-emerald-400" />
                <span>Privacy Policy</span>
              </button>
            </div>

            {/* Copyright and Legal Notice */}
            <div className="flex flex-col sm:flex-row items-center justify-between gap-4 text-xs text-white/40">
              <p>© 2026 Anis&apos; Home Media Server. All rights reserved.</p>
              <p>Self-hosted private streaming · Zero telemetry · Direct hardware pipeline</p>
            </div>
          </div>
        </footer>
      ) : null}

      {/* Privacy Policy Glass Modal */}
      {privacyOpen && typeof document !== 'undefined'
        ? createPortal(
            <div
              role="dialog"
              aria-modal="true"
              aria-labelledby="privacy-dialog-title"
              className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/75 backdrop-blur-md overflow-y-auto animate-overlay-fade"
              onClick={() => setPrivacyOpen(false)}
            >
              <div
                className="glass-card max-w-lg w-full my-auto rounded-3xl p-6 sm:p-8 space-y-5 shadow-2xl border border-white/15 animate-scale-in"
                onClick={(e) => e.stopPropagation()}
              >
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2.5">
                    <div className="flex h-9 w-9 items-center justify-center rounded-full bg-emerald-500/15 border border-emerald-500/30 text-emerald-400">
                      <Icon name="shield" size={18} />
                    </div>
                    <h3 id="privacy-dialog-title" className="text-lg font-bold text-white">
                      Privacy Policy
                    </h3>
                  </div>
                  <button
                    type="button"
                    onClick={() => setPrivacyOpen(false)}
                    className="flex h-8 w-8 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/70 hover:bg-white/10 hover:text-white transition cursor-pointer"
                    aria-label="Close dialog"
                  >
                    ✕
                  </button>
                </div>

                <div className="space-y-3 text-xs sm:text-sm text-white/70 leading-relaxed">
                  <p>
                    <strong>Anis&apos; Home Media Server</strong> is a private, self-hosted media platform. It does not collect, transmit, or share personal data, browsing behavior, or watch activity with any external third parties.
                  </p>
                  <p>
                    Playback progress, user accounts, and device pairing tokens are persisted entirely within a local SQLite database (<code>media.db</code>) on your host machine.
                  </p>
                  <p>
                    Remote access is routed through a dedicated Cloudflare Named Tunnel strictly as an encrypted transport bridge; no advertising trackers, analytics SDKs, or third-party cookies are used.
                  </p>
                </div>

                <div className="pt-2 flex justify-end">
                  <button
                    type="button"
                    onClick={() => setPrivacyOpen(false)}
                    className="rounded-full brand-gradient px-5 py-2 text-xs font-semibold text-white shadow-md hover:scale-105 active:scale-95 transition cursor-pointer"
                  >
                    Close
                  </button>
                </div>
              </div>
            </div>,
            document.body
          )
        : null}
    </div>
  );
}

export default AppShell;