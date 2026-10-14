import { createPortal } from 'react-dom';
import { Icon } from '../../../components/icons';
import type { MovieItem } from '../../../lib/api/manage';
import { posterUrl } from '../../../lib/api/poster';

interface DeleteConfirmationModalProps {
  readonly deleteTarget: MovieItem | null;
  readonly deleting: boolean;
  readonly isAdmin: boolean;
  readonly adminPin: string;
  readonly modalPinInput: string;
  readonly email: string | null | undefined;
  readonly onChangePinInput: (value: string) => void;
  readonly onConfirmDelete: () => void;
  readonly onClose: () => void;
}

export function DeleteConfirmationModal({
  deleteTarget,
  deleting,
  isAdmin,
  adminPin,
  modalPinInput,
  email,
  onChangePinInput,
  onConfirmDelete,
  onClose,
}: DeleteConfirmationModalProps) {
  if (!deleteTarget || typeof document === 'undefined') return null;

  return createPortal(
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="purgeModalTitle"
      className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-md overflow-y-auto animate-overlay-fade"
    >
      <div
        className="relative w-full max-w-md my-auto rounded-3xl border border-rose-500/40 bg-obsidian-950 p-6 sm:p-7 shadow-2xl space-y-5 animate-scale-in"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Modal Header */}
        <div className="flex items-start justify-between gap-3">
          <div className="flex items-center gap-3">
            <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-rose-500/20 text-rose-400 border border-rose-500/40 shrink-0">
              <Icon name="trash" size={20} />
            </span>
            <div>
              <h3 id="purgeModalTitle" className="text-lg font-bold text-white">
                Permanently Delete &amp; Purge?
              </h3>
              <p className="text-xs text-rose-300/80 font-medium">This action cannot be undone</p>
            </div>
          </div>
          <button
            type="button"
            disabled={deleting}
            onClick={onClose}
            className="rounded-full p-1.5 text-white/50 hover:bg-white/10 hover:text-white transition cursor-pointer"
            aria-label="Close dialog"
          >
            ✕
          </button>
        </div>

        {/* Target Media Card */}
        <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-3.5 flex items-center gap-3">
          <div className="h-14 w-10 rounded-lg overflow-hidden bg-white/5 border border-white/10 shrink-0">
            {deleteTarget.poster ? (
              <img
                src={posterUrl(deleteTarget.poster) ?? ''}
                alt={deleteTarget.title}
                className="h-full w-full object-cover"
              />
            ) : (
              <div className="h-full w-full flex items-center justify-center text-xs text-white/30">
                🎬
              </div>
            )}
          </div>
          <div className="min-w-0 flex-1">
            <p className="font-bold text-sm text-white truncate">
              {deleteTarget.title} {deleteTarget.year ? `(${deleteTarget.year})` : ''}
            </p>
            <p className="font-mono text-[11px] text-white/40 truncate">{deleteTarget.filename}</p>
          </div>
        </div>

        {/* What will be purged checklist */}
        <div className="rounded-2xl border border-rose-500/20 bg-rose-500/5 p-4 space-y-2 text-xs">
          <span className="font-bold text-rose-300 block">
            Associated data that will be completely wiped:
          </span>
          <ul className="space-y-1.5 text-white/70">
            <li className="flex items-center gap-2">
              <span className="text-rose-400">✕</span>
              <span>Source video file on disk</span>
            </li>
            <li className="flex items-center gap-2">
              <span className="text-rose-400">✕</span>
              <span>HLS transcode cache chunks &amp; live seek thumbnails</span>
            </li>
            <li className="flex items-center gap-2">
              <span className="text-rose-400">✕</span>
              <span>Sidecar subtitles &amp; TMDb metadata records</span>
            </li>
            <li className="flex items-center gap-2">
              <span className="text-rose-400">✕</span>
              <span>Client watch progress and resume points</span>
            </li>
          </ul>
        </div>

        {/* Admin PIN input if not yet unlocked */}
        {!adminPin ? (
          <div className="rounded-2xl border border-rose-500/30 bg-rose-500/10 p-4 space-y-2">
            <label className="text-xs font-bold text-rose-300 flex items-center gap-1.5">
              <Icon name="shield" size={13} />
              Admin PIN Required
            </label>
            <input
              type="password"
              maxLength={8}
              value={modalPinInput}
              onChange={(e) => onChangePinInput(e.target.value)}
              placeholder="Enter 4-digit PIN…"
              className="w-full rounded-xl border border-rose-500/40 bg-obsidian-900/90 px-3.5 py-2 text-sm text-white placeholder-white/30 focus:border-rose-400 focus:outline-none"
            />
            <p className="text-[11px] text-white/50">
              Authorized as {email || 'Administrator'} or enter your Admin PIN to authorize
              deletion.
            </p>
          </div>
        ) : null}

        {/* Modal Actions */}
        <div className="flex items-center justify-end gap-3 pt-2">
          <button
            type="button"
            disabled={deleting}
            onClick={onClose}
            className="rounded-full border border-white/15 bg-white/5 hover:bg-white/10 text-white/80 px-4 py-2 text-xs font-semibold transition cursor-pointer"
          >
            Cancel
          </button>
          <button
            type="button"
            disabled={deleting || (!isAdmin && !modalPinInput)}
            onClick={onConfirmDelete}
            className="rounded-full bg-rose-600 hover:bg-rose-500 text-white px-5 py-2 text-xs font-bold transition flex items-center gap-2 shadow-lg shadow-rose-600/30 cursor-pointer disabled:opacity-40"
          >
            {deleting ? (
              <>
                <span className="h-3 w-3 rounded-full border-2 border-white/20 border-t-white animate-spin" />
                <span>Purging File…</span>
              </>
            ) : (
              <>
                <Icon name="trash" size={13} />
                <span>Yes, Delete &amp; Purge Everything</span>
              </>
            )}
          </button>
        </div>
      </div>
    </div>,
    document.body
  );
}
