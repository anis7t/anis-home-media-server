import { useEffect } from 'react';

import { useAuth } from '../../auth/AuthProvider';
import Avatar from '../../components/Avatar';
import { QrSignInPanel } from '../../components/QrSignInPanel';

export function AccountPage() {
  const {
    authenticated,
    loading: authLoading,
    email,
    name,
    role,
    signIn,
    signOut,
    oauthConfigured,
    openPinSignIn,
  } = useAuth();

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    if (params.get('error') === 'oauth_unconfigured') {
      openPinSignIn();
    }
  }, [openPinSignIn]);

  return (
    <div className="mx-auto max-w-3xl space-y-8 animate-fade-in">
      {/* Account Profile Header Card */}
      <section className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl">
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-6">
          <div className="flex items-center gap-4">
            <div className="relative">
              <Avatar size="lg" label={authenticated ? (name ?? email ?? 'Account') : 'Guest'} />
              <div
                className={`absolute -bottom-1 -right-1 flex h-5 w-5 items-center justify-center rounded-full ring-2 ring-obsidian-900 ${
                  authenticated ? 'bg-emerald-500' : 'bg-amber-500'
                }`}
                title={authenticated ? 'Online' : 'Guest'}
              >
                <span className="h-2 w-2 rounded-full bg-white"></span>
              </div>
            </div>
            <div className="min-w-0">
              <div className="flex items-center gap-2.5">
                <h1 className="text-2xl font-bold tracking-tight text-white">Account</h1>
                {authenticated && role ? (
                  <span className="rounded-full bg-brand-500/20 px-2.5 py-0.5 text-xs font-semibold uppercase tracking-wider text-brand-300 border border-brand-500/30">
                    {role}
                  </span>
                ) : (
                  <span className="rounded-full bg-white/10 px-2.5 py-0.5 text-xs font-semibold text-white/60 border border-white/10">
                    Guest Mode
                  </span>
                )}
              </div>
              {authenticated ? (
                <>
                  <p className="mt-1 text-sm text-white/60">
                    Signed in as <span className="text-white/90 font-medium">{name ?? email}</span>
                  </p>
                  {email ? <p className="text-xs text-white/40">{email}</p> : null}
                </>
              ) : (
                <>
                  <p className="mt-1 text-sm text-white/60">
                    Not signed in · Browsing as a local guest
                  </p>
                  {!oauthConfigured && (
                    <p className="mt-1 text-xs text-amber-400/80">
                      Google Sign-In is not configured on this server. Use Admin PIN to sign in.
                    </p>
                  )}
                </>
              )}
            </div>
          </div>

          {authenticated && (
            <button
              type="button"
              onClick={signOut}
              className="self-start sm:self-auto rounded-full border border-white/15 bg-white/5 px-5 py-2 text-xs font-semibold text-white/80 shadow-sm transition hover:border-white/30 hover:bg-white/10 hover:text-white active:scale-95 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-400"
            >
              Sign out
            </button>
          )}
        </div>
      </section>

      {/* QR Device Sign-In Panel
       *
       * The only way to sign another screen in. It is short-lived, single-use,
       * and confirmed on the phone that scans it.
       *
       * Gated on `!authLoading` as well as `!authenticated`. Before the
       * auth state resolves, `authenticated` is false for *everyone*, so
       * without the loading gate the panel mounted for signed-in users too:
       * it flashed a "Sign in" card at someone who was already signed in,
       * and it fired `POST /api/auth/qr` - creating a pair session on the
       * server - for every account-page visit by an authenticated user.
       */}
      {!authLoading && !authenticated && (
        <section aria-label="QR Device Sign-In" className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl">
          <div className="mb-6">
            <h2 className="text-xl font-bold text-white">Sign In to Anis&apos; Home Media Server</h2>
            <p className="mt-1 text-xs text-white/50">
              Scan with your phone to pair this device, or sign in directly below.
            </p>
          </div>
          <QrSignInPanel
            onGoogleSignIn={signIn}
            onPinSignIn={openPinSignIn}
            oauthConfigured={oauthConfigured}
          />
        </section>
      )}

      {/* Session Management Section - Active Session only */}
      {authenticated && (
        <section aria-labelledby="session-heading" className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-4">
          <h2 id="session-heading" className="text-lg font-bold text-white">
            Active Session
          </h2>
          <p className="text-xs text-white/50">
            Sign out will clear your session cookie on this browser. You can sign back in at any time with Google Sign-In.
          </p>
          <button
            type="button"
            onClick={signOut}
            className="card-ring rounded-full border border-white/15 bg-white/5 px-5 py-2.5 text-sm font-semibold text-white hover:bg-white/10 active:scale-95 transition"
          >
            Sign out
          </button>
        </section>
      )}
    </div>
  );
}

export default AccountPage;
