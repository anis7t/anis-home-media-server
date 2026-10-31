import { useRef, useEffect, useState, useId } from 'react';
import { createPortal } from 'react-dom';
import { Icon } from '../../../components/icons';

export interface AdminPinModalProps {
  readonly isOpen: boolean;
  readonly pinValue?: string;
  readonly error: string | null;
  readonly busy?: boolean;
  readonly onChangePin: (value: string) => void;
  readonly onSubmit: (code?: string) => void;
  readonly onClose: () => void;
}

export function AdminPinModal({
  isOpen,
  pinValue = '',
  error,
  busy = false,
  onChangePin,
  onSubmit,
  onClose,
}: AdminPinModalProps) {
  const [digits, setDigits] = useState<string[]>(['', '', '', '', '', '']);
  const inputRefs = useRef<(HTMLInputElement | null)[]>([]);
  const titleId = useId();
  const descId = useId();

  // Synchronize internal cells when modal opens
  useEffect(() => {
    if (isOpen) {
      const chars = (pinValue || '').split('').slice(0, 6);
      const newDigits = ['', '', '', '', '', ''];
      chars.forEach((c, i) => {
        if (/^\d$/.test(c)) newDigits[i] = c;
      });
      setDigits(newDigits);
      setTimeout(() => {
        inputRefs.current[0]?.focus();
      }, 50);
    } else {
      setDigits(['', '', '', '', '', '']);
    }
  }, [isOpen]);

  // Handle escape key
  useEffect(() => {
    if (!isOpen) return;
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && !busy) onClose();
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [isOpen, busy, onClose]);

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
    onChangePin(fullCode);
    if (fullCode.length === 6 && next.every((d) => d !== '')) {
      onSubmit(fullCode);
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
      onChangePin(next.join(''));
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
    onChangePin(fullCode);
    if (fullCode.length === 6 && next.every((d) => d !== '')) {
      onSubmit(fullCode);
    }

    const focusTarget = Math.min(numbersOnly.length, 5);
    inputRefs.current[focusTarget]?.focus();
  };

  if (!isOpen || typeof document === 'undefined') return null;

  const isComplete = digits.every((d) => d !== '');

  return createPortal(
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby={titleId}
      aria-describedby={descId}
      className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-md overflow-y-auto animate-overlay-fade"
      onClick={(e) => {
        if (e.target === e.currentTarget && !busy) onClose();
      }}
    >
      <div
        className="relative w-full max-w-md my-auto rounded-3xl border border-brand-500/40 bg-obsidian-950 p-6 sm:p-7 shadow-2xl space-y-6 animate-scale-in text-white"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-start justify-between gap-3">
          <div className="flex items-center gap-3">
            <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-brand-500/20 text-brand-400 border border-brand-500/40">
              <Icon name="shield" size={20} />
            </span>
            <div>
              <h3 id={titleId} className="font-extrabold text-white text-lg tracking-tight">
                Administrator Verification
              </h3>
              <p id={descId} className="text-xs text-white/60">
                Enter your six-digit one-time access code
              </p>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            disabled={busy}
            className="text-white/40 hover:text-white cursor-pointer p-1 rounded-lg transition disabled:opacity-30"
            aria-label="Close dialog"
          >
            ✕
          </button>
        </div>

        {/* Error Feedback */}
        {error ? (
          <div className="rounded-2xl border border-rose-500/30 bg-rose-500/10 p-3.5 text-xs text-rose-300 flex items-center gap-2">
            <span>⚠️</span>
            <span>{error}</span>
          </div>
        ) : null}

        {/* Six Individual Numeric Input Cells */}
        <div className="space-y-4">
          <div
            className="flex items-center justify-center gap-2 sm:gap-2.5"
            onPaste={handlePaste}
          >
            {digits.map((digit, idx) => (
              <input
                key={idx}
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
                className="h-13 w-10 sm:h-14 sm:w-12 rounded-xl border border-white/20 bg-obsidian-900 text-center font-mono text-2xl font-extrabold text-white shadow-inner focus:border-brand-500 focus:bg-obsidian-850 focus:outline-none focus:ring-2 focus:ring-brand-500/30 transition disabled:opacity-50"
              />
            ))}
          </div>

          <p className="text-center text-[11px] text-white/50">
            Valid for 5 minutes · Single-use single redemption
          </p>
        </div>

        {/* Assistance / Link to Account Security */}
        <div className="rounded-xl border border-white/10 bg-white/[0.03] p-3 text-center">
          <p className="text-xs text-white/70">
            Need an access code?{' '}
            <a
              href="/account"
              className="text-brand-300 font-semibold hover:text-brand-200 underline ml-1"
            >
              Generate one in Account Security →
            </a>
          </p>
        </div>

        {/* Actions */}
        <div className="flex items-center justify-end gap-2.5 pt-1">
          <button
            type="button"
            onClick={onClose}
            disabled={busy}
            className="rounded-full border border-white/15 bg-white/5 px-4 py-2 text-xs font-semibold text-white/80 hover:bg-white/10 cursor-pointer disabled:opacity-40 transition"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={() => onSubmit(digits.join(''))}
            disabled={!isComplete || busy}
            className="rounded-full brand-gradient px-6 py-2 text-xs font-bold text-white shadow-md disabled:opacity-40 cursor-pointer flex items-center gap-1.5 transition hover:scale-[1.02] active:scale-[0.98]"
          >
            {busy ? (
              <>
                <span className="h-3 w-3 animate-spin rounded-full border-2 border-white/30 border-t-white" />
                <span>Verifying…</span>
              </>
            ) : (
              <span>Verify &amp; Unlock</span>
            )}
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}

export default AdminPinModal;
