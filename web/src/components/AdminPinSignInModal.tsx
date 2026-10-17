import { useState, useEffect, useRef, useCallback } from 'react';
import { createPortal } from 'react-dom';
import { Icon } from './icons';
import { loginWithPin } from '../lib/api/account';

export interface AdminPinSignInModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess?: () => void;
  oauthConfigured?: boolean;
}

export default function AdminPinSignInModal({
  isOpen,
  onClose,
  onSuccess,
  oauthConfigured = true,
}: AdminPinSignInModalProps) {
  const [pin, setPin] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [showConfigGuide, setShowConfigGuide] = useState(!oauthConfigured);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (isOpen) {
      setPin('');
      setError(null);
      setBusy(false);
      setShowConfigGuide(!oauthConfigured);
      setTimeout(() => inputRef.current?.focus(), 50);
    }
  }, [isOpen, oauthConfigured]);

  useEffect(() => {
    if (!isOpen) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [isOpen, onClose]);

  const handleSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();
      const trimmed = pin.trim();
      if (!trimmed) {
        setError('Please enter your Admin PIN.');
        return;
      }

      setBusy(true);
      setError(null);
      try {
        const res = await loginWithPin(trimmed);
        if (res.success) {
          onSuccess?.();
          onClose();
        } else {
          setError('Invalid Admin PIN. Please check and try again.');
        }
      } catch (err: any) {
        setError(err.message || 'Authentication failed. Please check your PIN.');
      } finally {
        setBusy(false);
      }
    },
    [pin, onSuccess, onClose]
  );

  if (!isOpen) return null;

  return createPortal(
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4 overflow-y-auto bg-black/80 backdrop-blur-md animate-overlay-fade"
      role="dialog"
      aria-modal="true"
      aria-labelledby="pinSignInTitle"
    >
      <div className="relative w-full max-w-md my-auto glass-card rounded-2xl border border-neutral-800/90 bg-neutral-900/95 p-6 sm:p-7 shadow-2xl text-white space-y-5 animate-scale-in">
        {/* Header */}
        <div className="flex items-start justify-between gap-3">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-xl bg-amber-500/10 border border-amber-500/20 flex items-center justify-center text-amber-400">
              <Icon name="shield" size={20} />
            </div>
            <div>
              <h2 id="pinSignInTitle" className="text-lg font-bold text-white">
                Admin PIN Sign-In
              </h2>
              <p className="text-xs text-neutral-400">
                {oauthConfigured
                  ? 'Sign in directly as Administrator with your secret PIN.'
                  : 'Google OAuth is unconfigured. Use local Admin PIN.'}
              </p>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="p-1 rounded-lg text-neutral-400 hover:text-white hover:bg-white/10 transition-colors"
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
                className="text-[11px] underline hover:text-white transition-colors"
              >
                {showConfigGuide ? 'Hide guide' : 'Setup guide'}
              </button>
            </div>
            <p className="text-neutral-300">
              The server lacks Google OAuth API keys. You can sign in locally using your Admin PIN to
              access management and TV pairing.
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

        {/* Form */}
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-1.5">
            <label htmlFor="adminPinInput" className="block text-xs font-medium text-neutral-300">
              Enter Administrator PIN
            </label>
            <input
              id="adminPinInput"
              ref={inputRef}
              type="password"
              inputMode="numeric"
              value={pin}
              onChange={(e) => setPin(e.target.value)}
              placeholder="••••"
              disabled={busy}
              className="w-full px-3.5 py-2.5 rounded-xl bg-neutral-950/70 border border-neutral-800 text-white placeholder-neutral-600 focus:outline-none focus:border-red-500 focus:ring-1 focus:ring-red-500 text-sm tracking-widest font-mono"
            />
          </div>

          {error && (
            <div className="p-2.5 rounded-lg bg-red-500/10 border border-red-500/30 text-xs text-red-400 flex items-center gap-2">
              <Icon name="x" size={14} className="shrink-0" />
              <span>{error}</span>
            </div>
          )}

          <div className="flex items-center justify-end gap-2.5 pt-2">
            <button
              type="button"
              onClick={onClose}
              disabled={busy}
              className="px-4 py-2 rounded-xl text-xs font-semibold text-neutral-400 hover:text-white hover:bg-white/5 transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={busy || !pin.trim()}
              className="inline-flex items-center justify-center gap-2 px-5 py-2 rounded-xl text-xs font-semibold bg-gradient-to-r from-red-600 to-red-700 hover:from-red-500 hover:to-red-600 text-white shadow-lg shadow-red-900/30 transition-all active:scale-95 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {busy ? (
                <>
                  <span className="w-3.5 h-3.5 border-2 border-white/30 border-t-white rounded-full animate-spin" />
                  <span>Verifying...</span>
                </>
              ) : (
                <span>Sign In as Admin</span>
              )}
            </button>
          </div>
        </form>
      </div>
    </div>,
    document.body
  );
}
