import { useState, useEffect } from 'react';
import { createPortal } from 'react-dom';
import { Icon } from '../../../components/icons';
import { changeAdminPin } from '../../../lib/api/manage';

export interface ChangeAdminPinModalProps {
  readonly isOpen: boolean;
  readonly defaultCurrentPin?: string;
  readonly onClose: () => void;
  readonly onSuccess: (newPin: string) => void;
}

export function ChangeAdminPinModal({
  isOpen,
  defaultCurrentPin = '',
  onClose,
  onSuccess,
}: ChangeAdminPinModalProps) {
  const [currentPin, setCurrentPin] = useState(defaultCurrentPin);
  const [newPin, setNewPin] = useState('');
  const [confirmPin, setConfirmPin] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  // Sync defaultCurrentPin if prop changes or when modal opens
  useEffect(() => {
    if (isOpen) {
      setCurrentPin(defaultCurrentPin || (typeof sessionStorage !== 'undefined' ? sessionStorage.getItem('ms_admin_pin') || '' : ''));
      setNewPin('');
      setConfirmPin('');
      setError(null);
      setSubmitting(false);
    }
  }, [isOpen, defaultCurrentPin]);

  // Handle escape key
  useEffect(() => {
    if (!isOpen) return;
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !submitting) {
        onClose();
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [isOpen, submitting, onClose]);

  if (!isOpen || typeof document === 'undefined') return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);

    const cleanNew = newPin.trim();
    const cleanConfirm = confirmPin.trim();

    if (cleanNew.length < 4) {
      setError('New PIN must be at least 4 digits');
      return;
    }

    if (!/^\d+$/.test(cleanNew)) {
      setError('New PIN must contain numeric digits only');
      return;
    }

    if (cleanNew !== cleanConfirm) {
      setError('New PIN and confirmation do not match');
      return;
    }

    setSubmitting(true);
    try {
      const res = await changeAdminPin({
        currentPin: currentPin.trim() || undefined,
        newPin: cleanNew,
      });

      if (res.success) {
        if (typeof sessionStorage !== 'undefined') {
          sessionStorage.setItem('ms_admin_pin', cleanNew);
          sessionStorage.setItem('ms_admin_unlocked', 'true');
        }
        onSuccess(cleanNew);
        onClose();
      } else {
        setError(res.error || 'Failed to update PIN. Verify your current PIN or admin session.');
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Network error while updating PIN');
    } finally {
      setSubmitting(false);
    }
  };

  return createPortal(
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="change-pin-modal-title"
      className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-md overflow-y-auto animate-overlay-fade"
      onClick={(e) => {
        if (e.target === e.currentTarget && !submitting) onClose();
      }}
    >
      <div
        className="relative w-full max-w-sm my-auto rounded-3xl border border-brand-500/40 bg-obsidian-950 p-6 shadow-2xl space-y-4 animate-scale-in"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2.5">
            <span className="flex h-9 w-9 items-center justify-center rounded-2xl bg-brand-500/20 text-brand-400 border border-brand-500/40">
              <Icon name="shield" size={18} />
            </span>
            <div>
              <h3 id="change-pin-modal-title" className="font-bold text-white text-base">
                Rotate Admin PIN
              </h3>
              <p className="text-xs text-white/50">Change administrative unlock PIN</p>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            disabled={submitting}
            className="text-white/40 hover:text-white cursor-pointer disabled:opacity-40"
            aria-label="Close dialog"
          >
            ✕
          </button>
        </div>

        {error ? (
          <div className="rounded-xl border border-rose-500/30 bg-rose-500/10 p-3 text-xs text-rose-300">
            ⚠️ {error}
          </div>
        ) : null}

        <form onSubmit={handleSubmit} className="space-y-3.5">
          <div>
            <label className="block text-xs font-semibold text-white/70 mb-1" htmlFor="current-pin-input">
              Current PIN
            </label>
            <input
              id="current-pin-input"
              type="password"
              inputMode="numeric"
              maxLength={12}
              value={currentPin}
              onChange={(e) => setCurrentPin(e.target.value)}
              placeholder="Enter current PIN…"
              className="w-full text-center tracking-widest text-base rounded-xl border border-white/20 bg-obsidian-900 py-2 px-3 text-white focus:border-brand-500 focus:outline-none"
            />
          </div>

          <div>
            <label className="block text-xs font-semibold text-white/70 mb-1" htmlFor="new-pin-input">
              New PIN (at least 4 digits)
            </label>
            <input
              id="new-pin-input"
              type="password"
              inputMode="numeric"
              maxLength={12}
              value={newPin}
              onChange={(e) => setNewPin(e.target.value)}
              placeholder="Enter new PIN…"
              className="w-full text-center tracking-widest text-base rounded-xl border border-white/20 bg-obsidian-900 py-2 px-3 text-white focus:border-brand-500 focus:outline-none"
            />
          </div>

          <div>
            <label className="block text-xs font-semibold text-white/70 mb-1" htmlFor="confirm-pin-input">
              Confirm New PIN
            </label>
            <input
              id="confirm-pin-input"
              type="password"
              inputMode="numeric"
              maxLength={12}
              value={confirmPin}
              onChange={(e) => setConfirmPin(e.target.value)}
              placeholder="Confirm new PIN…"
              className="w-full text-center tracking-widest text-base rounded-xl border border-white/20 bg-obsidian-900 py-2 px-3 text-white focus:border-brand-500 focus:outline-none"
            />
          </div>

          <div className="flex items-center justify-end gap-2.5 pt-2">
            <button
              type="button"
              onClick={onClose}
              disabled={submitting}
              className="rounded-full border border-white/15 bg-white/5 px-4 py-2 text-xs font-semibold text-white/80 hover:bg-white/10 cursor-pointer disabled:opacity-40"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={submitting || !newPin || !confirmPin}
              className="rounded-full brand-gradient px-5 py-2 text-xs font-bold text-white shadow-md disabled:opacity-40 cursor-pointer"
            >
              {submitting ? 'Updating…' : 'Rotate PIN'}
            </button>
          </div>
        </form>
      </div>
    </div>,
    document.body
  );
}
