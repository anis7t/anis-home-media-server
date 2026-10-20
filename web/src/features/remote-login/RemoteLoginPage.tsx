import { useCallback, useEffect, useRef, useState } from 'react';

import { confirmQrSession, lookupQrCode } from '../../lib/api/account';
import BrandMark from '../../components/BrandMark';

// ─── State machine ────────────────────────────────────────────────────────────

type Step =
  | 'loading'      // Checking session state
  | 'sign-in'      // Not authenticated — show Google sign-in
  | 'enter-code'   // Authenticated, but no QR params — ask for pair code
  | 'name-device'  // Code confirmed (or arrived via QR) — ask for device name
  | 'success'      // Pairing done 🎉
  | 'error';       // Something went wrong

// -- Brand lockup ---------------------------------------------------------

function BrandLockup() {
  return (
    <div className="flex flex-col items-center gap-3 mb-6">
      <BrandMark className="h-12 w-12" />
      <div className="text-center">
        <p className="text-base font-bold text-white">
          <span className="text-brand-400">Anis'</span> Home Media Server
        </p>
        <p className="text-[10px] tracking-[0.2em] text-white/35 mt-0.5">DEVICE SIGN-IN</p>
      </div>
    </div>
  );
}

// ─── Individual step views ────────────────────────────────────────────────────

function SignInStep({ googleSignInUrl }: { googleSignInUrl: string }) {
  return (
    <div className="space-y-6 text-center">
      <div>
        <h1 className="text-xl font-bold text-white">Sign in first</h1>
        <p className="mt-2 text-sm text-white/55 leading-relaxed">
          You need to sign in on this device to pair your TV or browser.
        </p>
      </div>
      <a
        href={googleSignInUrl}
        id="rl-google-signin"
        className="flex w-full items-center justify-center gap-3 rounded-2xl border border-white/15 bg-white/5 px-5 py-3.5 text-sm font-semibold text-white transition hover:bg-white/10 hover:border-white/25 active:scale-95"
      >
        <svg viewBox="0 0 48 48" className="h-5 w-5 shrink-0" aria-hidden="true">
          <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/>
          <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/>
          <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/>
          <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.18 1.48-4.97 2.31-8.16 2.31-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/>
          <path fill="none" d="M0 0h48v48H0z"/>
        </svg>
        Continue with Google
      </a>
    </div>
  );
}

interface EnterCodeStepProps {
  onConfirm: (code: string) => void;
  error: string | null;
  busy: boolean;
}

function EnterCodeStep({ onConfirm, error, busy }: EnterCodeStepProps) {
  const [digits, setDigits] = useState<string[]>(['', '', '', '', '']);
  const inputRefs = useRef<(HTMLInputElement | null)[]>([]);

  const handleChange = (index: number, value: string) => {
    const char = value.replace(/[^a-zA-Z0-9]/g, '').toUpperCase().slice(-1);
    const newDigits = [...digits];
    newDigits[index] = char;
    setDigits(newDigits);

    if (char && index < 4) {
      inputRefs.current[index + 1]?.focus();
    }
    // Auto-submit when all 5 filled
    if (char && index === 4 && newDigits.every((d) => d)) {
      onConfirm(newDigits.join(''));
    }
  };

  const handleKeyDown = (index: number, e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Backspace' && !digits[index] && index > 0) {
      inputRefs.current[index - 1]?.focus();
    }
  };

  const handlePaste = (e: React.ClipboardEvent) => {
    e.preventDefault();
    const text = e.clipboardData.getData('text').replace(/[^a-zA-Z0-9]/g, '').toUpperCase().slice(0, 5);
    const newDigits = [...digits];
    [...text].forEach((char, i) => { if (i < 5) newDigits[i] = char; });
    setDigits(newDigits);
    inputRefs.current[Math.min(text.length, 4)]?.focus();
    if (text.length === 5) onConfirm(text);
  };

  const code = digits.join('');

  return (
    <div className="space-y-6">
      <div className="text-center">
        <h1 className="text-xl font-bold text-white">Enter pairing code</h1>
        <p className="mt-2 text-sm text-white/55 leading-relaxed">
          Enter the 5-character code shown on your TV or browser.
        </p>
      </div>

      {/* 5-box code input */}
      <div className="flex items-center justify-center gap-2.5" onPaste={handlePaste}>
        {digits.map((digit, i) => (
          <input
            key={i}
            ref={(el) => { inputRefs.current[i] = el; }}
            id={`rl-code-${i}`}
            type="text"
            inputMode="text"
            maxLength={1}
            value={digit}
            onChange={(e) => handleChange(i, e.target.value)}
            onKeyDown={(e) => handleKeyDown(i, e)}
            autoFocus={i === 0}
            className="h-14 w-12 rounded-xl border border-white/20 bg-white/5 text-center font-mono text-xl font-bold text-white uppercase caret-brand-400 outline-none transition focus:border-brand-500/70 focus:bg-white/10 focus:ring-2 focus:ring-brand-500/25"
            aria-label={`Code digit ${i + 1}`}
          />
        ))}
      </div>

      {error && (
        <p className="rounded-xl border border-brand-500/30 bg-brand-500/10 px-4 py-2.5 text-center text-sm text-brand-400">
          {error}
        </p>
      )}

      <button
        type="button"
        id="rl-code-confirm"
        disabled={busy || code.length < 5}
        onClick={() => onConfirm(code)}
        className="w-full rounded-2xl brand-gradient brand-glow-sm px-5 py-3.5 text-sm font-bold text-white shadow-md transition hover:scale-[1.02] active:scale-[0.98] disabled:opacity-40 disabled:hover:scale-100"
      >
        {busy ? 'Verifying…' : 'Continue →'}
      </button>
    </div>
  );
}

interface NameDeviceStepProps {
  onConfirm: (name: string) => void;
  error: string | null;
  busy: boolean;
}

function NameDeviceStep({ onConfirm, error, busy }: NameDeviceStepProps) {
  const [name, setName] = useState('');

  const suggestions = ['Living room TV', 'Bedroom Fire Stick', 'Office PC', 'Kitchen tablet'];

  return (
    <div className="space-y-6">
      <div className="text-center">
        <h1 className="text-xl font-bold text-white">Name this device</h1>
        <p className="mt-2 text-sm text-white/55 leading-relaxed">
          Give the TV or browser a friendly name so you can identify it later.
        </p>
      </div>

      <div className="space-y-3">
        <input
          id="rl-device-name"
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter' && name.trim()) onConfirm(name.trim()); }}
          placeholder="e.g. Living room TV"
          maxLength={60}
          autoFocus
          className="w-full rounded-2xl border border-white/15 bg-white/5 px-4 py-3.5 text-sm text-white placeholder:text-white/30 outline-none transition focus:border-brand-500/60 focus:bg-white/10 focus:ring-2 focus:ring-brand-500/20"
        />

        {/* Quick suggestions */}
        <div className="flex flex-wrap gap-2">
          {suggestions.map((s) => (
            <button
              key={s}
              type="button"
              onClick={() => setName(s)}
              className="rounded-full border border-white/15 bg-white/5 px-3 py-1 text-xs text-white/60 transition hover:border-brand-500/30 hover:bg-brand-500/10 hover:text-brand-300"
            >
              {s}
            </button>
          ))}
        </div>
      </div>

      {error && (
        <p className="rounded-xl border border-brand-500/30 bg-brand-500/10 px-4 py-2.5 text-center text-sm text-brand-400">
          {error}
        </p>
      )}

      <button
        type="button"
        id="rl-pair-confirm"
        disabled={busy || !name.trim()}
        onClick={() => onConfirm(name.trim())}
        className="w-full rounded-2xl brand-gradient brand-glow-sm px-5 py-3.5 text-sm font-bold text-white shadow-md transition hover:scale-[1.02] active:scale-[0.98] disabled:opacity-40 disabled:hover:scale-100"
      >
        {busy ? 'Signing in your TV…' : 'Pair device →'}
      </button>
    </div>
  );
}

function SuccessStep({ deviceName }: { deviceName: string }) {
  return (
    <div className="text-center space-y-5 py-4">
      <div className="flex justify-center">
        <div className="flex h-16 w-16 items-center justify-center rounded-full bg-emerald-500/20 border border-emerald-500/30">
          <svg viewBox="0 0 24 24" fill="none" className="h-8 w-8 text-emerald-400" aria-hidden="true">
            <path d="M5 13l4 4L19 7" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </div>
      </div>
      <div>
        <h1 className="text-xl font-bold text-white">All done!</h1>
        <p className="mt-2 text-sm text-white/60 leading-relaxed">
          <span className="font-medium text-white/80">{deviceName}</span> is now signed in.
          <br />
          Your TV or browser should have already loaded the library.
        </p>
      </div>
      <p className="text-xs text-white/35">You can close this tab.</p>
    </div>
  );
}

// ─── Main page ────────────────────────────────────────────────────────────────

/**
 * `/remotelogin` — Phone-side page for completing a QR device sign-in.
 *
 * Handles two flows:
 * - **QR scan**: URL params include `?qr_id=&code=&sig=` → skip code entry
 * - **Manual**: Visitor typed the URL → ask for pair code, then device name
 *
 * This page is NOT inside AppShell (no header/nav). It's a standalone
 * full-page card optimized for mobile use.
 */
export function RemoteLoginPage() {
  const params = new URLSearchParams(window.location.search);
  const qrId = params.get('qr_id');
  const qrCode = params.get('code');
  const qrSig = params.get('sig');
  const hasSigFlow = Boolean(qrId && qrCode && qrSig);

  const [step, setStep] = useState<Step>('loading');
  const [resolvedQrId, setResolvedQrId] = useState<string | null>(qrId);
  const [resolvedCode, setResolvedCode] = useState<string | null>(qrCode);
  const resolvedSig = qrSig;
  const [deviceName, setDeviceName] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // Detect current auth state
  useEffect(() => {
    fetch('/api/auth/me', { credentials: 'same-origin' })
      .then((r) => r.json())
      .then((data: { authenticated?: boolean }) => {
        const authed = Boolean(data?.authenticated);

        if (!authed) {
          setStep('sign-in');
        } else if (hasSigFlow) {
          // QR scan — code + sig already in URL
          setStep('name-device');
        } else {
          setStep('enter-code');
        }
      })
      .catch(() => {
        setStep('sign-in');
      });
  }, [hasSigFlow]);

  // Google sign-in URL — preserves all QR params so they survive the redirect
  const googleReturnUrl = `/remotelogin?${params.toString()}`;
  const googleSignInUrl = `/auth/google?next=${encodeURIComponent(googleReturnUrl)}`;

  // Handle pair code entry
  const handleCodeSubmit = useCallback(async (code: string) => {
    setBusy(true);
    setError(null);
    try {
      const result = await lookupQrCode(code);
      setResolvedQrId(result.qr_id);
      setResolvedCode(result.code);
      setStep('name-device');
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : 'Invalid or expired pairing code. Please check your TV screen.',
      );
    } finally {
      setBusy(false);
    }
  }, []);

  // Handle final pairing confirm
  const handlePairConfirm = useCallback(
    async (name: string) => {
      if (!resolvedQrId) {
        setError('Session ID missing. Please scan the QR code again.');
        return;
      }
      setBusy(true);
      setError(null);
      try {
        await confirmQrSession(resolvedQrId, name, {
          code: resolvedCode ?? undefined,
          sig: resolvedSig ?? undefined,
        });
        setDeviceName(name);
        setStep('success');
      } catch (err) {
        const msg =
          err instanceof Error
            ? err.message
            : 'Something went wrong. Please check the code and try again.';
        setError(msg);
      } finally {
        setBusy(false);
      }
    },
    [resolvedQrId, resolvedCode, resolvedSig],
  );

  return (
    <div
      className="min-h-screen flex items-center justify-center px-4 py-8"
      style={{
        background:
          'radial-gradient(ellipse at 30% 20%, rgba(229,9,20,0.12) 0%, transparent 60%), #090b10',
      }}
    >
      <div className="w-full max-w-sm">
        <BrandLockup />

        {/* Card */}
        <div className="glass-card rounded-3xl p-7 shadow-2xl animate-fade-in">
          {step === 'loading' && (
            <div className="flex flex-col items-center gap-4 py-6">
              <div className="h-8 w-8 rounded-full border-2 border-white/10 border-t-brand-500 animate-spin" />
              <p className="text-sm text-white/50">Loading…</p>
            </div>
          )}

          {step === 'sign-in' && (
            <SignInStep googleSignInUrl={googleSignInUrl} />
          )}

          {step === 'enter-code' && (
            <EnterCodeStep
              onConfirm={handleCodeSubmit}
              error={error}
              busy={busy}
            />
          )}

          {step === 'name-device' && (
            <NameDeviceStep
              onConfirm={handlePairConfirm}
              error={error}
              busy={busy}
            />
          )}

          {step === 'success' && (
            <SuccessStep deviceName={deviceName} />
          )}

          {step === 'error' && (
            <div className="text-center space-y-4 py-4">
              <p className="text-sm text-brand-400">{error}</p>
              <button
                type="button"
                onClick={() => window.location.assign('/remotelogin')}
                className="text-xs text-white/50 underline underline-offset-2 hover:text-white/80"
              >
                Start over
              </button>
            </div>
          )}
        </div>

        {/* Footer */}
        <p className="mt-5 text-center text-[11px] text-white/25">
          Anis' Home Media Server · Secure device pairing
        </p>
      </div>
    </div>
  );
}

export default RemoteLoginPage;
