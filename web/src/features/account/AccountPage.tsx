import { useCallback, useEffect, useState } from 'react';

import { useAuth } from '../../auth/AuthProvider';
import Avatar from '../../components/Avatar';
import {
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
  const { email, name, role, signOut } = useAuth();
  const [tokens, setTokens] = useState<TokenRecord[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [label, setLabel] = useState('');
  const [busy, setBusy] = useState(false);
  const [minted, setMinted] = useState<MintedToken | null>(null);

  const load = useCallback(async () => {
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
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

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
    <div className="mx-auto max-w-3xl space-y-8">
      <header>
        <div className="flex items-center gap-3">
          <Avatar size="md" label={name ?? 'Account'} />
          <div>
            <h1 className="text-2xl font-bold text-white">Account</h1>
            <p className="mt-1 text-sm text-white/55">
              Signed in as <span className="text-white/80">
                {name ?? email ?? 'unknown'}
              </span>
              {role ? (
                <span className="ml-2 rounded bg-white/10 px-2 py-0.5 text-xs uppercase text-white/60">
                  {role}
                </span>
              ) : null}
            </p>
            <p className="mt-0.5 text-xs text-white/40">{email}</p>
          </div>
        </div>
      </header>

      <section aria-labelledby="tokens-heading" className="space-y-4">
        <h2 id="tokens-heading" className="text-lg font-semibold text-white">
          Devices
        </h2>
        <p className="text-sm text-white/50">
          A device token signs the Android app or a TV in as you, so your watch
          history and player settings follow you between them.
        </p>

        {role === 'admin' ? (
          <form onSubmit={onMint} className="flex flex-wrap items-center gap-2">
            <label htmlFor="token-label" className="sr-only">
              Device name
            </label>
            <input
              id="token-label"
              value={label}
              onChange={(event) => setLabel(event.target.value)}
              placeholder="Living room TV"
              maxLength={60}
              className="min-w-48 flex-1 rounded-lg border border-white/15 bg-white/5 px-3 py-2 text-sm text-white placeholder:text-white/30"
            />
            <button
              type="submit"
              disabled={busy || label.trim().length === 0}
              className="card-ring rounded-lg brand-gradient px-4 py-2 text-sm font-semibold text-white disabled:opacity-40"
            >
              {busy ? 'Working…' : 'Add device'}
            </button>
          </form>
        ) : (
          <p className="rounded-lg border border-white/10 bg-white/5 p-3 text-xs text-white/50">
            Only an administrator can add devices.
          </p>
        )}

        {minted ? <MintedTokenPanel minted={minted} onDismiss={() => setMinted(null)} /> : null}

        {error ? (
          <p className="rounded-lg border border-brand-500/40 bg-brand-500/10 p-3 text-xs text-brand-400">
            {error}
          </p>
        ) : null}

        {tokens === null ? (
          <p className="text-sm text-white/50" role="status">
            Loading devices…
          </p>
        ) : tokens.length === 0 ? (
          <p className="text-sm text-white/50" role="status">
            No devices yet.
          </p>
        ) : (
          <ul className="space-y-2">
            {tokens.map((token) => {
              const status = statusOf(token);
              return (
                <li
                  key={token.id}
                  className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-white/10 bg-obsidian-800 p-4"
                >
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium text-white">{token.label}</p>
                    <p className="mt-0.5 text-xs text-white/45">
                      Created {formatDate(token.created_at)} · Last used{' '}
                      {formatDate(token.last_used_at)}
                      {token.expires_at ? ` · Expires ${formatDate(token.expires_at)}` : ''}
                    </p>
                  </div>
                  <div className="flex items-center gap-3">
                    <span className={`rounded px-2 py-0.5 text-xs ${status.className}`}>
                      {status.label}
                    </span>
                    {!token.revoked_at ? (
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => void onRevoke(token.id)}
                        className="card-ring rounded border border-white/15 px-3 py-1 text-xs text-white/70 hover:bg-white/10 disabled:opacity-40"
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

      <section aria-labelledby="session-heading" className="space-y-3">
        <h2 id="session-heading" className="text-lg font-semibold text-white">
          Session
        </h2>
        <button
          type="button"
          onClick={signOut}
          className="card-ring rounded-lg border border-white/15 px-4 py-2 text-sm font-semibold text-white hover:bg-white/10"
        >
          Sign out
        </button>
      </section>
    </div>
  );
}

export default AccountPage;