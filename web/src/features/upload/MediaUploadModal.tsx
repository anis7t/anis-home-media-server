import { useCallback, useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Icon } from '../../components/icons';
import { useMediaUpload } from './useMediaUpload';
import {
  isSupportedMediaFile,
  MAX_UPLOAD_BYTES,
  type UploadSuccess,
} from './uploadApi';

export interface MediaUploadModalProps {
  readonly open: boolean;
  readonly onClose: () => void;
  readonly onUploaded: (result: UploadSuccess) => void;
  readonly onNeedPin: () => void;
  readonly adminPin?: string | null;
}

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const index = Math.min(
    Math.floor(Math.log(bytes) / Math.log(1024)),
    units.length - 1,
  );
  const value = bytes / 1024 ** index;
  return `${value.toFixed(index === 0 ? 0 : 1)} ${units[index]}`;
}

function formatEta(seconds: number | null): string {
  if (seconds === null || !Number.isFinite(seconds)) return 'Calculating…';
  if (seconds <= 1) return 'Almost done';
  if (seconds < 60) return `${Math.ceil(seconds)}s left`;
  if (seconds < 3600) {
    const minutes = Math.floor(seconds / 60);
    const remainder = Math.ceil(seconds % 60);
    return `${minutes}m ${remainder}s left`;
  }
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.ceil((seconds % 3600) / 60);
  return `${hours}h ${minutes}m left`;
}

export function MediaUploadModal({
  open,
  onClose,
  onUploaded,
  onNeedPin,
  adminPin,
}: MediaUploadModalProps) {
  const { state, start, abort, reset } = useMediaUpload();
  const [file, setFile] = useState<File | null>(null);
  const [title, setTitle] = useState('');
  const [overwrite, setOverwrite] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const notifiedRef = useRef(false);

  const isBusy = state.phase === 'uploading' || state.phase === 'processing';

  const handleClose = useCallback(() => {
    if (state.phase === 'uploading') abort();
    onClose();
  }, [abort, onClose, state.phase]);

  useEffect(() => {
    if (!open) {
      setFile(null);
      setTitle('');
      setOverwrite(false);
      setLocalError(null);
      reset();
    }
  }, [open, reset]);

  useEffect(() => {
    if (state.phase === 'success' && state.result && !notifiedRef.current) {
      notifiedRef.current = true;
      onUploaded(state.result);
    }
    if (state.phase !== 'success') {
      notifiedRef.current = false;
    }
  }, [onUploaded, state.phase, state.result]);

  useEffect(() => {
    if (!open) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') handleClose();
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [handleClose, open]);

  if (!open || typeof document === 'undefined') return null;

  const selectFiles = (files: FileList | null) => {
    const selected = files?.[0];
    if (!selected || isBusy) return;
    if (!isSupportedMediaFile(selected.name)) {
      setLocalError(
        'Unsupported format. Use MP4, MKV, WebM, MOV, AVI, or M4V.',
      );
      return;
    }
    if (selected.size <= 0) {
      setLocalError('The selected file is empty.');
      return;
    }
    if (selected.size > MAX_UPLOAD_BYTES) {
      setLocalError('The selected file exceeds the 20 GiB limit.');
      return;
    }
    setLocalError(null);
    setFile(selected);
    setTitle('');
    setOverwrite(false);
    reset();
  };

  const handleStart = () => {
    if (!file || isBusy) return;
    void start({
      file,
      adminPin,
      title: title.trim() || undefined,
      overwrite,
    });
  };

  const percent = Math.round(Math.min(Math.max(state.progress, 0), 1) * 100);

  return createPortal(
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="upload-modal-title"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 p-4 backdrop-blur-md overflow-y-auto animate-overlay-fade"
      onClick={(event) => {
        if (event.target === event.currentTarget && !isBusy) handleClose();
      }}
    >
      <div
        className="relative my-auto w-full max-w-xl max-h-[calc(100vh-2rem)] overflow-y-auto rounded-3xl border border-white/10 bg-obsidian-950 p-5 shadow-2xl animate-scale-in sm:p-6"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="flex items-start justify-between gap-4">
          <div className="flex items-center gap-3">
            <span className="flex h-10 w-10 items-center justify-center rounded-2xl border border-brand-500/40 bg-brand-500/15 text-brand-400">
              <Icon name="upload" size={19} />
            </span>
            <div>
              <h2
                id="upload-modal-title"
                className="text-base font-bold text-white"
              >
                Upload media
              </h2>
              <p className="text-xs text-white/50">
                Resumable 8 MiB chunks · up to 20 GiB
              </p>
            </div>
          </div>
          <button
            type="button"
            onClick={handleClose}
            aria-label="Close upload dialog"
            className="rounded-full p-1.5 text-white/40 hover:bg-white/10 hover:text-white"
          >
            <Icon name="x" size={17} />
          </button>
        </div>

        {state.phase === 'success' && state.result ? (
          <div className="mt-5 space-y-4">
            <div className="rounded-2xl border border-emerald-500/30 bg-emerald-500/10 p-4">
              <div className="flex items-center gap-2 text-emerald-300">
                <Icon name="check" size={17} />
                <p className="text-sm font-semibold">Upload complete</p>
              </div>
              <p className="mt-1 text-sm text-white">
                {state.result.title || state.result.filename}
              </p>
              <p className="mt-0.5 text-xs text-white/50">
                {state.result.year ? `${state.result.year} · ` : ''}
                Indexing in the library now
              </p>
            </div>
            <div className="flex flex-wrap items-center justify-end gap-2.5">
              <a
                href={state.result.details_url}
                className="rounded-full border border-white/15 bg-white/5 px-4 py-2 text-xs font-semibold text-white/85 hover:bg-white/10"
              >
                View details
              </a>
              <button
                type="button"
                onClick={() => {
                  setFile(null);
                  setTitle('');
                  setOverwrite(false);
                  reset();
                }}
                className="rounded-full brand-gradient px-5 py-2 text-xs font-bold text-white shadow-md"
              >
                Upload another
              </button>
            </div>
          </div>
        ) : (
          <div className="mt-5 space-y-4">
            <label
              htmlFor="media-upload-input"
              onDragOver={(event) => event.preventDefault()}
              onDrop={(event) => {
                event.preventDefault();
                selectFiles(event.dataTransfer.files);
              }}
              className={`flex cursor-pointer flex-col items-center justify-center rounded-2xl border border-dashed border-white/20 bg-white/[0.03] px-5 py-7 text-center transition hover:border-brand-500/50 hover:bg-brand-500/5 ${
                isBusy ? 'pointer-events-none opacity-60' : ''
              }`}
            >
              <input
                id="media-upload-input"
                type="file"
                accept=".mp4,.mkv,.webm,.mov,.avi,.m4v,video/*"
                className="sr-only"
                disabled={isBusy}
                onChange={(event) => selectFiles(event.target.files)}
              />
              <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-brand-500/15 text-brand-400">
                <Icon name="upload" size={21} />
              </span>
              <span className="mt-3 text-sm font-semibold text-white">
                {file ? file.name : 'Choose a video or drag it here'}
              </span>
              <span className="mt-1 text-xs text-white/45">
                {file
                  ? formatBytes(file.size)
                  : 'MP4, MKV, WebM, MOV, AVI, M4V'}
              </span>
            </label>

            {localError ? (
              <div
                role="alert"
                className="rounded-xl border border-rose-500/30 bg-rose-500/10 p-3 text-xs text-rose-300"
              >
                {localError}
              </div>
            ) : null}

            {file ? (
              <div className="space-y-3">
                <div>
                  <label
                    htmlFor="media-upload-title"
                    className="mb-1.5 block text-xs font-medium text-white/70"
                  >
                    Display title <span className="text-white/35">(optional)</span>
                  </label>
                  <input
                    id="media-upload-title"
                    type="text"
                    value={title}
                    onChange={(event) => setTitle(event.target.value)}
                    disabled={isBusy}
                    placeholder="Leave blank to use the filename"
                    className="w-full rounded-xl border border-white/15 bg-obsidian-900 px-3.5 py-2.5 text-sm text-white placeholder-white/35 focus:border-brand-500/70 focus:outline-none focus:ring-2 focus:ring-brand-500/20 disabled:opacity-60"
                  />
                </div>

                <label className="flex items-center gap-2 text-xs text-white/60">
                  <input
                    type="checkbox"
                    checked={overwrite}
                    onChange={(event) => setOverwrite(event.target.checked)}
                    disabled={isBusy}
                    className="h-4 w-4 rounded border-white/20 bg-obsidian-900 accent-brand-500"
                  />
                  Replace an existing file with the same name
                </label>
                <p className="text-[11px] text-white/35">
                  Off by default: a duplicate gets a unique (1), (2) name instead
                  of overwriting.
                </p>
              </div>
            ) : null}

            {state.phase === 'uploading' || state.phase === 'processing' ? (
              <div className="space-y-2">
                <div className="flex items-center justify-between gap-3 text-xs">
                  <span className="font-semibold text-white">
                    {state.phase === 'processing'
                      ? 'Processing upload…'
                      : `Uploading ${percent}%`}
                  </span>
                  <span className="text-white/50">
                    {state.etaSeconds !== null
                      ? formatEta(state.etaSeconds)
                      : 'Starting…'}
                  </span>
                </div>
                <div className="h-2 overflow-hidden rounded-full bg-white/10">
                  <div
                    className="h-full rounded-full brand-gradient transition-[width] duration-200"
                    style={{ width: `${percent}%` }}
                  />
                </div>
                <div className="flex items-center justify-between gap-3 text-[11px] text-white/45">
                  <span>
                    {formatBytes(state.uploadedBytes)} of{' '}
                    {formatBytes(state.totalBytes)}
                  </span>
                  <span>
                    {state.speedBytesPerSecond
                      ? `${formatBytes(state.speedBytesPerSecond)}/s`
                      : ''}
                  </span>
                </div>
              </div>
            ) : null}

            {state.error ? (
              <div className="space-y-2.5">
                <div
                  role="alert"
                  className="rounded-xl border border-rose-500/30 bg-rose-500/10 p-3 text-xs text-rose-300"
                >
                  {state.error}
                </div>
                {state.errorStatus === 403 ? (
                  <button
                    type="button"
                    onClick={onNeedPin}
                    className="rounded-full border border-amber-500/40 bg-amber-500/10 px-4 py-2 text-xs font-semibold text-amber-200 hover:bg-amber-500/15"
                  >
                    Enter Admin PIN
                  </button>
                ) : null}
              </div>
            ) : null}

            <div className="flex flex-wrap items-center justify-end gap-2.5 pt-1">
              {isBusy ? (
                <button
                  type="button"
                  onClick={() => {
                    abort();
                    onClose();
                  }}
                  className="rounded-full border border-white/15 bg-white/5 px-4 py-2 text-xs font-semibold text-white/80 hover:bg-white/10"
                >
                  Abort upload
                </button>
              ) : (
                <>
                  <button
                    type="button"
                    onClick={handleClose}
                    className="rounded-full border border-white/15 bg-white/5 px-4 py-2 text-xs font-semibold text-white/80 hover:bg-white/10"
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    onClick={handleStart}
                    disabled={!file}
                    className="inline-flex items-center gap-2 rounded-full brand-gradient px-5 py-2 text-xs font-bold text-white shadow-md disabled:cursor-not-allowed disabled:opacity-40"
                  >
                    <Icon name="upload" size={14} />
                    Start upload
                  </button>
                </>
              )}
            </div>
          </div>
        )}
      </div>
    </div>,
    document.body,
  );
}

export default MediaUploadModal;
