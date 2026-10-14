import { fireEvent, render } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { CacheStatusDialog, ShellTranscodePill, TranscodeCard } from './TranscodeCard';

describe('TranscodeCard suite', () => {
  const buildingTranscode = {
    status: 'building' as const,
    percent: 45.5,
    speed: 2.4,
    encoded: 540,
    duration: 1200,
    remaining: 275,
    bytes: 104857600,
  };

  const readyTranscode = {
    status: 'ready' as const,
    percent: 100,
    speed: 3.1,
    encoded: 1200,
    duration: 1200,
    remaining: 0,
    bytes: 250000000,
  };

  it('renders TranscodeCard with progress and telemetry while building', () => {
    render(<TranscodeCard transcode={buildingTranscode} isReady={false} />);
    const card = document.getElementById('playerTranscodeCard');
    expect(card).not.toBeNull();
    expect(card?.style.display).toBe('block');
    expect(document.getElementById('ptcTitle')?.textContent).toContain('Transcoding in Progress');
    expect(document.getElementById('ptcPct')?.textContent).toBe('45.5%');
    expect(document.getElementById('ptcFill')?.style.width).toBe('45.5%');
    expect(document.getElementById('ptcTime')?.textContent).toBe('9:00 / 20:00');
    expect(document.getElementById('ptcSpeed')?.textContent).toBe('2.4×');
    expect(document.getElementById('ptcEta')?.textContent).toContain('4m 35s remaining');
  });

  it('renders TranscodeCard complete state when ready', () => {
    render(<TranscodeCard transcode={readyTranscode} isReady={true} />);
    expect(document.getElementById('ptcTitle')?.textContent).toBe('✓ Transcoding Complete');
    expect(document.getElementById('ptcPct')?.textContent).toBe('100%');
    expect(document.getElementById('ptcFill')?.style.width).toBe('100%');
    expect(document.getElementById('ptcEta')?.textContent).toBe('Ready for stream');
    expect(document.getElementById('ptcPulse')?.className).toContain('idle');
  });

  it('renders ShellTranscodePill with live transcode percentage', () => {
    render(<ShellTranscodePill transcode={buildingTranscode} isReady={false} />);
    const pill = document.getElementById('shellTranscodePill');
    expect(pill).not.toBeNull();
    expect(document.getElementById('stpText')?.textContent).toBe('Transcoding 46% (2.4×)');
  });

  it('renders CacheStatusDialog and allows dismissal via Hide button', () => {
    render(
      <CacheStatusDialog
        transcode={buildingTranscode}
        isReady={false}
        isSeekingAhead={true}
        seekAheadTarget={800}
      />,
    );
    const dialog = document.getElementById('cacheStatus');
    expect(dialog).not.toBeNull();
    expect(dialog?.style.display).toBe('block');
    expect(document.getElementById('cacheMessage')?.textContent).toContain(
      'Preparing video up to 13:20',
    );

    const hideBtn = document.getElementById('cacheHideBtn');
    expect(hideBtn).not.toBeNull();
    fireEvent.click(hideBtn!);
    expect(dialog?.style.display).toBe('none');
  });
});
