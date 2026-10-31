import { useState, useEffect, useRef, useCallback, useId } from 'react';
import { createPortal } from 'react-dom';
import { Icon } from './icons';
import { verifyAdminOtp } from '../lib/api/account';

export interface AdminPinSignInModalProps {
  readonly isOpen: boolean;
  readonly onClose: () => void;
  readonly onSuccess?: () => void;
  readonly oauthConfigured?: boolean;
}

export default function AdminPinSignInModal({
  isOpen,
  onClose,
  onSuccess,
  oauthConfigured = true,
}: AdminPinSignInModalProps) {
  const [digits, setDigits] = useState<string[]>(['', '', '', '', '', '']);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [showConfigGuide, setShowConfigGuide] = useState(!oauthConfigured);
  const inputRefs = useRef<(HTMLInputElement | null)[]>([]);
  const titleId = useId();
  const descId = useId();

  useEffect(() => {
    if (isOpen) {
      setDigits(['', '', '', '', '', '']);
      setError(null);
      setBusy(false);
      setShowConfigGuide(!oauthConfigured);
      setTimeout(() => inputRefs.current[0]?.focus(), 50);
    }
  }, [isOpen, oauthConfigured]);

  useEffect(() => {
    if (!isOpen) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !busy) onClose();
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [isOpen, busy, onClose]);

  const handleVerify = useCallback(
    async (codeToVerify: string) => {
      const trimmed = codeToVerify.trim();
      if (trimmed.length !== 6) {
        setError('Please enter a 6-digit access code.');
        return;
      }

      setBusy(true);
      setError(null);
      try {
        const res = await verifyAdminOtp(trimmed);
        if (res.success) {
          onSuccess?.();
          onClose();
        } else {
          setError(res.error || 'Invalid or expired access code. Please try again.');
        }
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : 'Authentication failed. Please check your access code.';
        setError(msg);
      } finally {
        setBusy(false);
      }
    },
    [onSuccess, onClose],
  );

  const handleCellChange = (index: number, val: string) => {
    const cleaned = val.replace(/\D/g, '');
    const next = [...digits];
    let shouldAdvance = false;
    let targetIndex = index;

    if (!cleaned) {
      next[index] = '';
    } else if (cleaned.length > 1) {
      cleaned
        .slice(0, 6 - index)
        .split('')
        .forEach((char, offset) => {
          next[index + offset] = char;
        });
      targetIndex = Math.min(index + cleaned.length, 5);
      shouldAdvance = true;
    } else {
      next[index] = cleaned;
      if (index < 5) {
        targetIndex = index + 1;
        shouldAdvance = true;
      }
    }

    setDigits(next);
    const fullCode = next.join('');
    if (fullCode.length === 6 && next.every((d) => d !== '')) {
      void handleVerify(fullCode);
    }

    if (shouldAdvance) {
      inputRefs.current[targetIndex]?.focus();
    }
  };

  const handleKeyDown = (index: number, e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Backspace') {
      const next = [...digits];
      if (next[index]) {
        next[index] = '';
      } else if (index > 0) {
        inputRefs.current[index - 1]?.focus();
        next[index - 1] = '';
      }
      setDigits(next);
    } else if (e.key === 'ArrowLeft' && index > 0) {
      e.preventDefault();
      inputRefs.current[index - 1]?.focus();
    } else if (e.key === 'ArrowRight' && index < 5) {
      e.preventDefault();
      inputRefs.current[index + 1]?.focus();
    }
  };

  const handlePaste = (e: React.ClipboardEvent) => {
    e.preventDefault();
    const pasted = e.clipboardData.getData('text').trim();
    const numbersOnly = pasted.replace(/\D/g, '').slice(0, 6);
    if (!numbersOnly) return;

    const next = ['', '', '', '', '', ''];
    numbersOnly.split('').forEach((char, i) => {
      next[i] = char;
    });
    setDigits(next);

    const fullCode = next.join('');
    if (fullCode.length === 6 && next.every((d) => d !== '')) {
      void handleVerify(fullCode);
    }

    const focusTarget = Math.min(numbersOnly.length, 5);
    inputRefs.current[focusTarget]?.focus();
  };

  if (!isOpen) return null;

  const isComplete = digits.every((d) => d !== '') && digits.join('').length === 6;

  return createPortal(
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4 overflow-y-auto bg-black/80 backdrop-blur-md animate-overlay-fade"
      role="dialog"
      aria-modal="true"
      aria-labelledby={titleId}
      aria-describedby={descId}
    >
      <div className="relative w-full max-w-md my-auto glass-card rounded-2xl border border-neutral-800/90 bg-neutral-900/95 p-6 sm:p-7 shadow-2xl text-white space-y-5 animate-scale-in">
        {/* Header */}
        <div className="flex items-start justify-between gap-3">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-xl bg-amber-500/10 border border-amber-500/20 flex items-center justify-center text-amber-400">
              <Icon name="shield" size={20} />
            </div>
            <div>
              <h2 id={titleId} className="text-lg font-bold text-white">
                Administrator Verification
              </h2>
              <p id={descId} className="text-xs text-neutral-400">
                Enter your six-digit one-time access code.
              </p>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            disabled={busy}
            className="p-1 rounded-lg text-neutral-400 hover:text-white hover:bg-white/10 transition-colors cursor-pointer"
            aria-label="Close dialog"
          >
            <Icon name="x" size={18} />
          </button>
        </div>

        {/* Notice when Google Sign-in is not configured in .env */}
        {!oauthConfigured && (
          <div className="rounded-xl border border-amber-500/30 bg-amber-500/10 p-3 space-y-2 text-xs text-amber-200/90">
            <div className="flex items-center justify-between font-semibold">
              <span className="flex items-center gap-1.5">
                <span className="text-amber-400">ℹ️</span> Google Sign-In Not Configured
              </span>
              <button
                type="button"
                onClick={() => setShowConfigGuide((v) => !v)}
                className="text-[11px] underline hover:text-white transition-colors cursor-pointer"
              >
                {showConfigGuide ? 'Hide guide' : 'Setup guide'}
              </button>
            </div>
            <p className="text-neutral-300">
              The server lacks Google OAuth API keys. Generate an access code from an administrator account
              to access management and TV pairing.
            </p>

            {showConfigGuide && (
              <div className="mt-2 pt-2 border-t border-amber-500/20 space-y-1 font-mono text-[11px]">
                <p className="text-neutral-400 font-sans">To enable Google OAuth, add to .env:</p>
                <div className="bg-neutral-950/80 p-2 rounded border border-neutral-800 text-neutral-300 overflow-x-auto select-all">
                  GOOGLE_CLIENT_ID=your-id.apps.googleusercontent.com<br />
                  GOOGLE_CLIENT_SECRET=GOCSPX-your-secret
                </div>
              </div>
            )}
          </div>
        )}

        {/* Form with 6 discrete numeric input cells */}
        <form
          onSubmit={(e) => {
            e.preventDefault();
            void handleVerify(digits.join(''));
          }}
          className="space-y-4"
        >
          <div className="space-y-2">
            <label htmlFor="cell-0" className="block text-center text-xs font-medium text-neutral-300">
              Enter 6-Digit Access Code
            </label>
            <div className="flex items-center justify-center gap-2 sm:gap-2.5" onPaste={handlePaste}>
              {digits.map((digit, idx) => (
                <input
                  key={idx}
                  id={`cell-${idx}`}
                  ref={(el) => {
                    inputRefs.current[idx] = el;
                  }}
                  type="text"
                  inputMode="numeric"
                  pattern="[0-9]*"
                  maxLength={1}
                  disabled={busy}
                  value={digit}
                  onChange={(e) => handleCellChange(idx, e.target.value)}
                  onKeyDown={(e) => handleKeyDown(idx, e)}
                  aria-label={`Digit ${idx + 1} of 6`}
                  className="h-12 w-10 sm:h-13 sm:w-11 rounded-xl border border-neutral-800 bg-neutral-950/80 text-center font-mono text-xl font-extrabold text-white shadow-inner focus:border-red-500 focus:bg-neutral-900 focus:outline-none focus:ring-2 focus:ring-red-500/30 transition disabled:opacity-50"
                />
              ))}
            </div>
            <p className="text-center text-[11px] text-neutral-400">
              Valid for 5 minutes · Single-use single redemption
            </p>
          </div>

          {error && (
            <div className="p-2.5 rounded-lg bg-red-500/10 border border-red-500/30 text-xs text-red-400 flex items-center gap-2">
              <Icon name="x" size={14} className="shrink-0" />
              <span>{error}</span>
            </div>
          )}

          {/* Assistance / Link to Account Security */}
          <div className="rounded-xl border border-white/10 bg-white/[0.03] p-3 text-center">
            <p className="text-xs text-white/70">
              Need an access code?{' '}
              <a
                href="/account"
                className="text-red-400 font-semibold hover:text-red-300 underline ml-1"
              >
                Generate one in Account Security →
              </a>
            </p>
          </div>

          <div className="flex items-center justify-end gap-2.5 pt-2">
            <button
              type="button"
              onClick={onClose}
              disabled={busy}
              className="px-4 py-2 rounded-xl text-xs font-semibold text-neutral-400 hover:text-white hover:bg-white/5 transition-colors cursor-pointer"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={busy || !isComplete}
              className="inline-flex items-center justify-center gap-2 px-5 py-2 rounded-xl text-xs font-semibold bg-gradient-to-r from-red-600 to-red-700 hover:from-red-500 hover:to-red-600 text-white shadow-lg shadow-red-900/30 transition-all active:scale-95 disabled:opacity-50 disabled:cursor-not-allowed cursor-pointer"
            >
              {busy ? (
                <>
                  <span className="w-3.5 h-3.5 border-2 border-white/30 border-t-white rounded-full animate-spin" />
                  <span>Verifying...</span>
                </>
              ) : (
                <span>Verify &amp; Sign In</span>
              )}
            </button>
          </div>
        </form>
      </div>
    </div>,
    document.body,
  );
}
