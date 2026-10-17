import { render, screen, fireEvent } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { TranscodeGate } from './TranscodeGate';

describe('TranscodeGate component', () => {
  it('renders hardware transcode badge and title', () => {
    render(
      <TranscodeGate
        filename="Movies/Inception (2010).mkv"
        transcode={{
          status: 'building',
          percent: 45,
          speed: 2.8,
          remaining: 120,
          duration: 9000,
          encoded: 4050,
          bytes: 12000000,
        }}
      />
    );

    expect(screen.getByRole('region', { name: /transcode progress gate/i })).toBeInTheDocument();
    expect(screen.getByText(/Dual AMD GPU Transcoder Active/i)).toBeInTheDocument();
    expect(screen.getByText(/Building a transcode for 'Inception \(2010\)'/i)).toBeInTheDocument();
  });

  it('renders progress percentage, speed, and ETA', () => {
    render(
      <TranscodeGate
        filename="Test.mkv"
        transcode={{
          status: 'building',
          percent: 75.4,
          speed: 3.5,
          remaining: 85,
          duration: 3600,
          encoded: 2700,
          bytes: 50000000,
        }}
      />
    );

    expect(screen.getByText(/75%/i)).toBeInTheDocument();
    expect(screen.getByText(/3.5×/i)).toBeInTheDocument();
    expect(screen.getByText(/1m 25s/i)).toBeInTheDocument();

    const fill = document.getElementById('transcodeGateFill');
    expect(fill).toHaveStyle({ width: '75.4%' });
  });

  it('calls onRefresh when check status button is clicked during active transcode', () => {
    const handleRefresh = vi.fn();
    render(
      <TranscodeGate
        filename="Test.mkv"
        transcode={{
          status: 'building',
          percent: 30,
          speed: 2.0,
          remaining: 90,
          duration: 3600,
          encoded: 1080,
          bytes: 10000000,
        }}
        onRefresh={handleRefresh}
      />
    );

    const btn = screen.getByRole('button', { name: /check status/i });
    fireEvent.click(btn);
    expect(handleRefresh).toHaveBeenCalledTimes(1);
  });

  it('renders Pre-Transcode Required with queue button when transcode is idle', () => {
    const handleQueue = vi.fn();
    render(
      <TranscodeGate
        filename="Test.mkv"
        transcode={{
          status: 'idle',
          percent: 0,
          duration: 3600,
          encoded: 0,
          speed: 0,
        }}
        diagnosticReason="Matroska (.mkv) container cannot be decoded natively by this web browser"
        onQueuePreTranscode={handleQueue}
      />
    );

    expect(screen.getByText('Pre-Transcode Required')).toBeInTheDocument();
    expect(screen.getByText(/Pre-transcode required for 'Test'/i)).toBeInTheDocument();
    expect(
      screen.getByText('Matroska (.mkv) container cannot be decoded natively by this web browser'),
    ).toBeInTheDocument();

    const queueBtn = screen.getByTestId('queue-pre-transcode-btn');
    expect(queueBtn).toBeInTheDocument();
    fireEvent.click(queueBtn);
    expect(handleQueue).toHaveBeenCalledTimes(1);
  });
});
