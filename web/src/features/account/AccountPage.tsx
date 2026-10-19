import { useCallback, useEffect, useState } from 'react';

import { useAuth } from '../../auth/AuthProvider';
import Avatar from '../../components/Avatar';
import {
  getStoredAdminPin,
  listTokens,
  mintToken,
  revokeToken,
  type MintedToken,
  type TokenRecord,
} from '../../lib/api/account';
import { MintedTokenPanel } from '../../components/PairingQr';

function formatDate(seconds: number | null): string {
  if (!seconds) return '—';
  return new Date(seconds * 1000).toLocaleString();
}

function statusOf(token: TokenRecord): { label: string; className: string } {
  if (token.revoked_at) return { label: 'Revoked', className: 'bg-white/10 text-white/50' };
  if (token.expires_at && token.expires_at * 1000 <= Date.now()) {
    return { label: 'Expired', className: 'bg-white/10 text-white/50' };
  }
  return { label: 'Active', className: 'bg-emerald-500/20 text-emerald-300' };
}

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
  const [tokens, setTokens] = useState<TokenRecord[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [label, setLabel] = useState('');
  const [busy, setBusy] = useState(false);
  const [minted, setMinted] = useState<MintedToken | null>(null);

  const hasPin = Boolean(getStoredAdminPin());
  const canManageTokens = authenticated || hasPin;

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    if (params.get('error') === 'oauth_unconfigured') {
      openPinSignIn();
    }
  }, [openPinSignIn]);

  const load = useCallback(async () => {
    if (!canManageTokens) {
      setTokens([]);
      setError(null);
      return;
    }
    try {
      const body = await listTokens();
      // Guard the shape: a malformed response must not white-screen the page by
      // handing `undefined` to .map().
      setTokens(Array.isArray(body.tokens) ? body.tokens : []);
      setError(null);
    } catch (cause) {
      setTokens([]);
      setError(cause instanceof Error ? cause.message : String(cause));
    }
  }, [canManageTokens]);

  useEffect(() => {
    if (!authLoading) {
      void load();
    }
  }, [authLoading, load]);

  const onMint = async (event: React.FormEvent) => {
    event.preventDefault();
    const trimmed = label.trim();
    if (!trimmed) return;
    setBusy(true);
    setError(null);
    try {
      const result = await mintToken(trimmed);
      // Shown once, then dropped from state so it cannot be re-read.
      setMinted(result);
      setLabel('');
      await load();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  const onRevoke = async (id: number) => {
    setBusy(true);
    try {
      await revokeToken(id);
      await load();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

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

          {authenticated ? (
            <button
              type="button"
              onClick={signOut}
              className="self-start sm:self-auto rounded-full border border-white/15 bg-white/5 px-5 py-2 text-xs font-semibold text-white/80 shadow-sm transition hover:border-white/30 hover:bg-white/10 hover:text-white active:scale-95 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-400"
            >
              Sign out
            </button>
          ) : (
            <div className="flex flex-wrap items-center gap-2.5 self-start sm:self-auto">
              <button
                type="button"
                onClick={openPinSignIn}
                className="rounded-full border border-white/15 bg-white/5 px-4 py-2 text-xs font-semibold text-white/80 shadow-sm transition hover:border-white/30 hover:bg-white/10 hover:text-white active:scale-95"
              >
                Sign in with Admin PIN
              </button>
              {oauthConfigured && (
                <button
                  type="button"
                  onClick={signIn}
                  className="card-ring brand-gradient brand-glow-sm rounded-full px-5 py-2 text-xs font-semibold text-white shadow-md transition hover:scale-105 active:scale-95"
                >
                  Sign in with Google →
                </button>
              )}
            </div>
          )}
        </div>
      </section>

      {/* Connected Devices Section */}
      <section aria-labelledby="tokens-heading" className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6">
        <div>
          <div className="flex flex-wrap items-center gap-2.5">
            <h2 id="tokens-heading" className="text-xl font-bold text-white">
              Devices &amp; TV App Pairing
            </h2>
            <span className="rounded-full bg-brand-500/15 border border-brand-500/25 px-2.5 py-0.5 text-xs font-semibold text-brand-300">
              For Android TV &amp; Fire TV
            </span>
          </div>
          <p className="mt-1.5 text-sm text-white/60">
            A device token signs the Android app or Fire TV in as your profile, syncing your watch
            history, resume points, and playback settings across screens without needing to type your Google password with a TV remote.
          </p>
          {authenticated && (
            <div className="mt-3 flex items-start gap-2.5 rounded-2xl border border-white/10 bg-white/[0.03] px-4 py-2.5 text-xs text-white/65">
              <span className="text-brand-400 font-semibold shrink-0">💡 Note for Web Users:</span>
              <span>
                Your web browser is already signed in! You only need to add a device here when pairing an external screen like an Android TV, Fire TV Stick, or phone.
              </span>
            </div>
          )}
        </div>

        {authenticated || Boolean(getStoredAdminPin()) ? (
          <form onSubmit={onMint} className="space-y-2">
            <div className="flex flex-wrap items-center gap-3">
              <label htmlFor="token-label" className="sr-only">
                Device name
              </label>
              <input
                id="token-label"
                value={label}
                onChange={(event) => setLabel(event.target.value)}
                placeholder="e.g. Living room TV or Bedroom Fire Stick"
                maxLength={60}
                className="min-w-64 flex-1 rounded-full border border-white/15 bg-obsidian-900/80 px-4 py-2.5 text-sm text-white placeholder:text-white/30 shadow-inner transition focus:border-brand-500/60 focus:bg-obsidian-900 focus:outline-none focus:ring-2 focus:ring-brand-500/20"
              />
              <button
                type="submit"
                disabled={busy || label.trim().length === 0}
                className="card-ring rounded-full brand-gradient brand-glow-sm px-6 py-2.5 text-sm font-semibold text-white shadow-md transition hover:scale-105 active:scale-95 disabled:opacity-40 disabled:hover:scale-100"
              >
                {busy ? 'Working…' : 'Add device'}
              </button>
            </div>
            <p className="text-[11px] text-white/40">
              Entering a name generates a one-time pairing token and QR code to sign in on your TV or phone.
            </p>
          </form>
        ) : (
          <div className="rounded-2xl border border-white/10 bg-white/5 p-4 text-xs text-white/60 flex flex-col sm:flex-row sm:items-center justify-between gap-3">
            <span>Sign in with Google or Admin PIN to generate pairing tokens for your Android TV, Fire TV Stick, or phone.</span>
            <button
              type="button"
              onClick={signIn}
              className="card-ring brand-gradient brand-glow-sm self-start sm:self-auto rounded-full px-4 py-1.5 text-xs font-semibold text-white whitespace-nowrap shadow-sm hover:scale-105 active:scale-95 transition"
            >
              Sign in to pair →
            </button>
          </div>
        )}

        {minted ? <MintedTokenPanel minted={minted} onDismiss={() => setMinted(null)} /> : null}

        {error ? (
          <p className="rounded-2xl border border-brand-500/40 bg-brand-500/10 p-4 text-xs font-medium text-brand-400">
            {error}
          </p>
        ) : null}

        {tokens === null ? (
          <div className="py-8 flex flex-col items-center justify-center space-y-3 animate-fade-in" role="status">
            <div className="h-7 w-7 rounded-full border-2 border-white/10 border-t-brand-500 animate-spin" />
            <p className="text-xs font-medium text-white/50 animate-pulse">
              Loading devices…
            </p>
          </div>
        ) : tokens.length === 0 ? (
          <div className="rounded-2xl border border-dashed border-white/10 p-8 text-center" role="status">
            <p className="text-sm font-medium text-white/60">No devices yet.</p>
            <p className="mt-1 text-xs text-white/40">
              {canManageTokens
                ? 'Add a device token above to pair your Android TV, phone, or tablet.'
                : 'Sign in to view your paired devices or generate a new TV pairing token.'}
            </p>
          </div>
        ) : (
          <ul className="space-y-3">
            {tokens.map((token) => {
              const status = statusOf(token);
              return (
                <li
                  key={token.id}
                  className="flex flex-wrap items-center justify-between gap-4 rounded-2xl border border-white/10 bg-obsidian-900/60 p-4.5 shadow-sm transition hover:border-white/20"
                >
                  <div className="min-w-0">
                    <p className="truncate text-sm font-semibold text-white">{token.label}</p>
                    <p className="mt-1 text-xs text-white/45">
                      Created {formatDate(token.created_at)} · Last used{' '}
                      {formatDate(token.last_used_at)}
                      {token.expires_at ? ` · Expires ${formatDate(token.expires_at)}` : ''}
                    </p>
                  </div>
                  <div className="flex items-center gap-3">
                    <span className={`rounded-full px-2.5 py-0.5 text-xs font-semibold ${status.className}`}>
                      {status.label}
                    </span>
                    {!token.revoked_at ? (
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => void onRevoke(token.id)}
                        className="card-ring rounded-full border border-white/15 bg-white/5 px-3.5 py-1 text-xs font-medium text-white/70 transition hover:border-rose-500/40 hover:bg-rose-500/15 hover:text-rose-300 disabled:opacity-40"
                      >
                        Revoke
                      </button>
                    ) : null}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </section>

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