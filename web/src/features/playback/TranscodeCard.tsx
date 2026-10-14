import React, { useState } from 'react';
import type { TranscodeStatusResponse } from '../../lib/api/types';

export interface TranscodeCardProps {
  transcode?: TranscodeStatusResponse;
  isReady?: boolean;
  needsTranscode?: boolean;
}

export interface CacheStatusProps {
  transcode?: TranscodeStatusResponse;
  isReady?: boolean;
  needsTranscode?: boolean;
  isSeekingAhead?: boolean;
  seekAheadTarget?: number;
}

export interface ShellTranscodePillProps {
  transcode?: TranscodeStatusResponse;
  isReady?: boolean;
  needsTranscode?: boolean;
}

function formatClock(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return '0:00';
  const total = Math.floor(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return h > 0
    ? `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
    : `${m}:${String(s).padStart(2, '0')}`;
}

function formatEta(seconds: number | null | undefined): string {
  if (seconds == null || !Number.isFinite(seconds) || seconds < 0) return 'calculating time';
  const s = Math.round(seconds);
  if (s >= 3600) {
    return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m remaining`;
  }
  return `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s remaining`;
}

/**
 * In-Player Viewport Transcode Pill (#shellTranscodePill)
 */
export const ShellTranscodePill: React.FC<ShellTranscodePillProps> = ({
  transcode,
  isReady = false,
  needsTranscode = false,
}) => {
  const hasTranscode = Boolean(transcode && transcode.status && transcode.status !== 'idle');
  const isComplete = isReady || transcode?.status === 'ready';
  const shouldShow = hasTranscode || needsTranscode;

  if (!shouldShow) return null;

  const pct = Math.min(100, Math.max(0, transcode?.percent ?? (isComplete ? 100 : 0)));
  const speedStr = transcode?.speed && transcode.speed > 0 ? `${transcode.speed.toFixed(1)}×` : '';

  return (
    <span
      id="shellTranscodePill"
      className="shell-transcode-pill"
      style={{ display: isComplete && !hasTranscode ? 'none' : 'inline-flex' }}
    >
      <span className="pulse-dot-sm" id="stpDot" />
      <span id="stpText">
        {isComplete
          ? '✓ Transcoded'
          : `Transcoding ${Math.round(pct)}%${speedStr ? ` (${speedStr})` : ''}`}
      </span>
    </span>
  );
};

/**
 * Cache Preparation Status Dialog (#cacheStatus) inside #shell
 */
export const CacheStatusDialog: React.FC<CacheStatusProps> = ({
  transcode,
  isReady = false,
  needsTranscode = false,
  isSeekingAhead = false,
  seekAheadTarget = 0,
}) => {
  const [dismissed, setDismissed] = useState(false);
  const isBuilding = transcode?.status === 'building' || transcode?.status === 'partial';
  const isComplete = isReady || transcode?.status === 'ready';

  const show =
    !dismissed &&
    ((isBuilding && (transcode?.encoded === 0 || isSeekingAhead)) ||
      (needsTranscode && !isComplete));

  const pct = Math.min(100, Math.max(0, transcode?.percent ?? (isComplete ? 100 : 0)));
  const speedStr = transcode?.speed && transcode.speed > 0 ? `${transcode.speed.toFixed(1)}×` : '';
  const etaStr = formatEta(transcode?.remaining);
  const encodedStr = formatClock(transcode?.encoded ?? 0);

  return (
    <div
      id="cacheStatus"
      hidden={!show}
      style={{ display: show ? 'block' : 'none' }}
    >
      <div className="cache-status-head">
        <strong>Preparing video</strong>
        <button
          id="cacheHideBtn"
          type="button"
          className="cache-hide-btn"
          aria-label="Hide preparation modal"
          onClick={() => setDismissed(true)}
        >
          Hide
        </button>
      </div>
      <span id="cacheMessage">
        {isSeekingAhead
          ? `Preparing video up to ${formatClock(seekAheadTarget)} (ready up to ${encodedStr})...`
          : transcode?.encoded === 0
            ? 'Converting for browser playback...'
            : `Preparing video · ${pct.toFixed(0)}% ready`}
      </span>
      <i>
        <b style={{ width: `${Math.max(4, pct)}%` }} />
      </i>
      <span id="cacheEta">
        ETA: {etaStr} {speedStr ? `· ${speedStr} speed` : ''}
      </span>
    </div>
  );
};

/**
 * Main Transcode Progress Card (#playerTranscodeCard) below #shell
 */
export const TranscodeCard: React.FC<TranscodeCardProps> = ({
  transcode,
  isReady = false,
  needsTranscode = false,
}) => {
  const hasTranscode = Boolean(transcode && transcode.status && transcode.status !== 'idle');
  const isComplete = isReady || transcode?.status === 'ready';
  const shouldShowCard = hasTranscode || needsTranscode;

  const pct = Math.min(100, Math.max(0, transcode?.percent ?? (isComplete ? 100 : 0)));
  const pctStr = `${pct.toFixed(1)}%`;
  const speedStr = transcode?.speed && transcode.speed > 0 ? `${transcode.speed.toFixed(1)}×` : '';
  const etaStr = formatEta(transcode?.remaining);
  const encodedStr = formatClock(transcode?.encoded ?? 0);
  const durationStr = formatClock(transcode?.duration ?? 0);

  return (
    <div
      id="playerTranscodeCard"
      className="player-transcode-card"
      style={{ display: shouldShowCard ? 'block' : 'none' }}
    >
      <div className="dtc-header">
        <div className="dtc-title-wrap">
          <span
            id="ptcPulse"
            className={`pulse-dot ${isComplete ? 'idle' : ''}`}
          />
          <span id="ptcTitle" className="dtc-title">
            {isComplete ? '✓ Transcoding Complete' : '⚡ Transcoding in Progress'}
          </span>
        </div>
        <span id="ptcPct" className="dtc-pct">
          {isComplete ? '100%' : pctStr}
        </span>
      </div>

      <div className="transcode-track">
        <div
          id="ptcFill"
          className="transcode-fill"
          style={{
            width: `${Math.max(2, pct)}%`,
            background: isComplete ? '#22c55e' : undefined,
          }}
        />
      </div>

      <div className="dtc-meta-row">
        <span id="ptcTime" className="dtc-time">
          {encodedStr} / {durationStr}
        </span>
        <span id="ptcSpeed" className="dtc-speed">
          {speedStr}
        </span>
        <span id="ptcEta" className="dtc-eta">
          {isComplete ? 'Ready for stream' : `ETA: ${etaStr}`}
        </span>
      </div>
    </div>
  );
};
