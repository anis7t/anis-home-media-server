import { useEffect, useState } from 'react';

import type { MintedToken } from '../lib/api/account';

interface PairingQrProps {
  readonly pairingUrl: string;
}

/**
 * QR for the pairing link, so a TV can be enrolled by scanning rather than by
 * typing a long URL on a 10-foot remote.
 *
 * `qrcode` is imported dynamically so its ~40 kB never lands in the initial
 * bundle - it is only needed on the account page, and Gate E budgets the initial
 * JavaScript.
 */
export function PairingQr({ pairingUrl }: PairingQrProps) {
  const [svg, setSvg] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setFailed(false);

    import('qrcode')
      .then((mod) =>
        mod.default.toString(pairingUrl, {
          type: 'svg',
          margin: 1,
          color: { dark: '#0d1017', light: '#ffffff' },
        }),
      )
      .then((markup: string) => {
        if (!cancelled) setSvg(markup);
      })
      .catch(() => {
        if (!cancelled) setFailed(true);
      });

    return () => {
      cancelled = true;
    };
  }, [pairingUrl]);

  if (failed) {
    return (
      <p className="rounded-lg border border-white/10 bg-obsidian-800 p-4 text-xs text-white/60">
        The QR code could not be generated. Copy the pairing link below instead.
      </p>
    );
  }

  if (!svg) {
    return <div className="h-48 w-48 animate-pulse rounded-lg bg-white/5" aria-hidden="true" />;
  }

  return (
    <div
      className="flex h-48 w-48 items-center justify-center rounded-lg bg-white p-2"
      /* SVG produced by `qrcode` from a value we generated ourselves. */
      dangerouslySetInnerHTML={{ __html: svg }}
      role="img"
      aria-label="Pairing QR code"
    />
  );
}

interface MintedPanelProps {
  readonly minted: MintedToken;
  readonly onDismiss: () => void;
}

/** Shows a freshly minted token exactly once, with a hard warning. */
export function MintedTokenPanel({ minted, onDismiss }: MintedPanelProps) {
  const [copied, setCopied] = useState<'token' | 'link' | null>(null);

  const copy = async (value: string, which: 'token' | 'link') => {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(which);
      window.setTimeout(() => setCopied(null), 2000);
    } catch {
      // Clipboard can be blocked; the value is on screen and selectable.
    }
  };

  return (
    <section
      className="rounded-xl border border-brand-500/40 bg-brand-500/10 p-5"
      role="status"
      aria-live="polite"
    >
      <h3 className="text-sm font-semibold text-brand-400">{minted.warning}</h3>

      <div className="mt-4 flex flex-col gap-4 sm:flex-row sm:items-start">
        <PairingQr pairingUrl={minted.pairing_url} />

        <div className="min-w-0 flex-1 space-y-3">
          <Field label="Pair this device">
            <code className="block break-all rounded bg-black/40 p-2 text-[11px] text-white/80">
              {minted.pairing_url}
            </code>
            <CopyButton
              copied={copied === 'link'}
              onClick={() => copy(minted.pairing_url, 'link')}
            />
          </Field>

          <Field label="Or paste the token directly">
            <code className="block break-all rounded bg-black/40 p-2 text-[11px] text-white/80">
              {minted.token}
            </code>
            <CopyButton copied={copied === 'token'} onClick={() => copy(minted.token, 'token')} />
          </Field>
        </div>
      </div>

      <button
        type="button"
        onClick={onDismiss}
        className="card-ring mt-4 rounded-lg bg-white/10 px-4 py-2 text-xs font-semibold text-white hover:bg-white/15"
      >
        I&apos;ve saved it
      </button>
    </section>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <p className="mb-1 text-[11px] uppercase tracking-wide text-white/40">{label}</p>
      {children}
    </div>
  );
}

function CopyButton({
  copied,
  onClick,
}: {
  copied: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="card-ring mt-1 rounded border border-white/15 px-2 py-1 text-[11px] text-white/70 hover:bg-white/10"
    >
      {copied ? 'Copied' : 'Copy'}
    </button>
  );
}

export default MintedTokenPanel;