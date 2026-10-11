import { NavLink } from 'react-router';

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

export function AppShell({ children }: { children: React.ReactNode }) {
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
          </nav>
        </div>
      </header>

      <main className="mx-auto max-w-[1600px] px-4 py-8 sm:px-6">{children}</main>
    </div>
  );
}

export default AppShell;