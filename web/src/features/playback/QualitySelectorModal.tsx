import { useEffect } from 'react';
import type { QualityOption } from '../../lib/api/types';

export interface QualitySelectorModalProps {
  isOpen: boolean;
  onClose: () => void;
  qualityLadder: QualityOption[];
  selectedQuality: string;
  onSelectQuality: (quality: string, option?: QualityOption) => void;
  supportsDirectPlay?: boolean;
  directPlayReason?: string;
}

export function QualitySelectorModal({
  isOpen,
  onClose,
  qualityLadder,
  selectedQuality,
  onSelectQuality,
  supportsDirectPlay = true,
  directPlayReason,
}: QualitySelectorModalProps) {
  useEffect(() => {
    if (!isOpen) return;

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        onClose();
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [isOpen, onClose]);

  if (!isOpen) return null;

  return (
    <div
      id="qualitySelectorModal"
      className="sub-modal quality-modal"
      onClick={(e) => e.stopPropagation()}
      data-testid="quality-selector-modal"
      role="dialog"
      aria-modal="true"
      aria-label="Playback Quality"
    >
      <div className="sub-modal-header">
        <div className="sub-modal-title-wrap">
          <span className="sub-modal-badge" aria-hidden="true">
            <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor">
              <path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 16H5V5h14v14zM7 15h1.5v-2h2v2H12V9h-1.5v2.5h-2V9H7v6zm10-5h-3.5v6H15c.83 0 1.5-.67 1.5-1.5v-3c0-.83-.67-1.5-1.5-1.5zm0 4.5h-2v-3h2v3z" />
            </svg>
          </span>
          <span className="modal-title font-semibold text-slate-100">Playback Quality</span>
        </div>
        <button
          id="closeQualityModal"
          type="button"
          onClick={onClose}
          className="sub-modal-close"
          aria-label="Close quality selector"
        >
          &times;
        </button>
      </div>

      <div className="mt-4 flex flex-col gap-2 max-h-[60vh] overflow-y-auto pr-1">
        {/* 1. Auto (Adaptive Stream) */}
        <button
          type="button"
          data-testid="quality-opt-auto"
          onClick={() => {
            onSelectQuality('auto');
            onClose();
          }}
          className={`flex items-center justify-between rounded-xl border px-3.5 py-3 text-left transition-all duration-150 ${
            selectedQuality === 'auto'
              ? 'border-brand-500/80 bg-brand-500/20 text-white shadow-sm'
              : 'border-white/10 bg-white/5 text-slate-300 hover:border-white/25 hover:bg-white/10'
          }`}
        >
          <div className="flex flex-col">
            <div className="flex items-center gap-2">
              <span className="text-sm font-semibold tracking-wide">Auto (Adaptive)</span>
              <span className="rounded bg-brand-500/30 px-1.5 py-0.5 text-[10px] font-medium text-brand-300">
                Recommended
              </span>
            </div>
            <span className="text-xs text-slate-400 mt-0.5">
              Dynamically streams pre-transcoded adaptive quality
            </span>
          </div>
          {selectedQuality === 'auto' && (
            <svg
              className="text-brand-400 flex-shrink-0"
              viewBox="0 0 20 20"
              width="18"
              height="18"
              fill="currentColor"
              aria-label="Active selection"
            >
              <path
                fillRule="evenodd"
                d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
                clipRule="evenodd"
              />
            </svg>
          )}
        </button>

        {/* 2. Dynamic Ladder Options */}
        {qualityLadder.map((opt) => {
          const isSelected =
            selectedQuality === opt.quality ||
            (opt.is_direct && selectedQuality === 'source');

          const isDirectUnsupported = opt.is_direct && !supportsDirectPlay;
          const isTierUnavailable = !opt.is_direct && !opt.is_ready;
          const isDisabled = isDirectUnsupported || isTierUnavailable;

          const mbps =
            opt.bitrate > 0 ? `${(opt.bitrate / 1_000_000).toFixed(1)} Mbps` : '';

          return (
            <button
              key={opt.quality}
              type="button"
              data-testid={`quality-opt-${opt.quality}`}
              disabled={isDisabled}
              onClick={() => {
                if (isDisabled) return;
                onSelectQuality(opt.quality, opt);
                onClose();
              }}
              className={`flex items-center justify-between rounded-xl border px-3.5 py-3 text-left transition-all duration-150 ${
                isDisabled
                  ? 'cursor-not-allowed opacity-55 border-white/5 bg-white/[0.02] text-slate-400'
                  : isSelected
                    ? 'border-brand-500/80 bg-brand-500/20 text-white shadow-sm'
                    : 'border-white/10 bg-white/5 text-slate-300 hover:border-white/25 hover:bg-white/10'
              }`}
            >
              <div className="flex flex-col">
                <div className="flex items-center gap-2">
                  <span className="text-sm font-semibold tracking-wide flex items-center gap-1.5">
                    {isDisabled && (
                      <svg viewBox="0 0 20 20" width="13" height="13" fill="currentColor" className="text-slate-400">
                        <path fillRule="evenodd" d="M5 9V7a5 5 0 0110 0v2a2 2 0 012 2v5a2 2 0 01-2 2H5a2 2 0 01-2-2v-5a2 2 0 012-2zm8-2v2H7V7a3 3 0 016 0z" clipRule="evenodd" />
                      </svg>
                    )}
                    {opt.label}
                  </span>
                  {opt.is_direct ? (
                    supportsDirectPlay ? (
                      <span className="rounded bg-sky-500/20 px-1.5 py-0.5 text-[10px] font-medium text-sky-300">
                        Direct Stream
                      </span>
                    ) : (
                      <span className="rounded bg-rose-500/20 px-1.5 py-0.5 text-[10px] font-medium text-rose-300">
                        Unsupported on this browser
                      </span>
                    )
                  ) : opt.is_ready ? (
                    <span className="rounded bg-emerald-500/20 px-1.5 py-0.5 text-[10px] font-medium text-emerald-300">
                      Stream Ready
                    </span>
                  ) : (
                    <span className="rounded bg-amber-500/20 px-1.5 py-0.5 text-[10px] font-medium text-amber-300">
                      Requires Pre-Transcode
                    </span>
                  )}
                </div>
                <span className="text-xs text-slate-400 mt-0.5">
                  {isDirectUnsupported
                    ? directPlayReason || 'Browser cannot decode MKV or Dolby Digital Plus (E-AC-3)'
                    : isTierUnavailable
                      ? 'Quality not pre-transcoded on server'
                      : `${opt.width && opt.height ? `${opt.width}×${opt.height}` : ''}${mbps ? ` · ${mbps}` : ''}`}
                </span>
              </div>
              {isSelected && !isDisabled && (
                <svg
                  className="text-brand-400 flex-shrink-0"
                  viewBox="0 0 20 20"
                  width="18"
                  height="18"
                  fill="currentColor"
                  aria-label="Active selection"
                >
                  <path
                    fillRule="evenodd"
                    d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
                    clipRule="evenodd"
                  />
                </svg>
              )}
            </button>
          );
        })}
      </div>
    </div>
  );
}
