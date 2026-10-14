import { createPortal } from 'react-dom';
import { Icon } from '../../../components/icons';

interface AdminPinModalProps {
  readonly isOpen: boolean;
  readonly pinValue: string;
  readonly error: string | null;
  readonly onChangePin: (value: string) => void;
  readonly onSubmit: () => void;
  readonly onClose: () => void;
}

export function AdminPinModal({
  isOpen,
  pinValue,
  error,
  onChangePin,
  onSubmit,
  onClose,
}: AdminPinModalProps) {
  if (!isOpen || typeof document === 'undefined') return null;

  return createPortal(
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="pin-modal-title"
      className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-md overflow-y-auto animate-overlay-fade"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
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
              <h3 id="pin-modal-title" className="font-bold text-white text-base">
                Unlock Admin Mode
              </h3>
              <p className="text-xs text-white/50">Enter your 4-digit PIN</p>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="text-white/40 hover:text-white cursor-pointer"
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

        <form
          onSubmit={(e) => {
            e.preventDefault();
            onSubmit();
          }}
          className="space-y-4"
        >
          <input
            type="password"
            maxLength={8}
            autoFocus
            value={pinValue}
            onChange={(e) => onChangePin(e.target.value)}
            placeholder="Admin PIN…"
            className="w-full text-center tracking-widest text-lg rounded-xl border border-white/20 bg-obsidian-900 py-2.5 px-4 text-white focus:border-brand-500 focus:outline-none"
          />

          <div className="flex items-center justify-end gap-2.5">
            <button
              type="button"
              onClick={onClose}
              className="rounded-full border border-white/15 bg-white/5 px-4 py-2 text-xs font-semibold text-white/80 hover:bg-white/10 cursor-pointer"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={!pinValue}
              className="rounded-full brand-gradient px-5 py-2 text-xs font-bold text-white shadow-md disabled:opacity-40 cursor-pointer"
            >
              Unlock
            </button>
          </div>
        </form>
      </div>
    </div>,
    document.body
  );
}
