import { render, screen, fireEvent } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { QualitySelectorModal } from './QualitySelectorModal';
import type { QualityOption } from '../../lib/api/types';

const MOCK_LADDER: QualityOption[] = [
  {
    label: 'Direct Play (Source)',
    quality: 'source',
    height: 1080,
    width: 1920,
    bitrate: 4500000,
    is_direct: true,
    is_ready: true,
    hls_url: null,
  },
  {
    label: '720p',
    quality: '720p',
    height: 720,
    width: 1280,
    bitrate: 2200000,
    is_direct: false,
    is_ready: true,
    hls_url: '/hls/test.mkv/720p/playlist.m3u8',
  },
  {
    label: '480p',
    quality: '480p',
    height: 480,
    width: 854,
    bitrate: 1200000,
    is_direct: false,
    is_ready: false,
    hls_url: '/hls/test.mkv/480p/playlist.m3u8',
  },
];

describe('QualitySelectorModal', () => {
  it('does not render when isOpen is false', () => {
    const { container } = render(
      <QualitySelectorModal
        isOpen={false}
        onClose={vi.fn()}
        qualityLadder={MOCK_LADDER}
        selectedQuality="auto"
        onSelectQuality={vi.fn()}
      />,
    );
    expect(container.firstChild).toBeNull();
  });

  it('renders Auto and all ladder options when open', () => {
    render(
      <QualitySelectorModal
        isOpen={true}
        onClose={vi.fn()}
        qualityLadder={MOCK_LADDER}
        selectedQuality="auto"
        onSelectQuality={vi.fn()}
        supportsDirectPlay={true}
      />,
    );

    expect(screen.getByTestId('quality-selector-modal')).toBeInTheDocument();
    expect(screen.getByText('Playback Quality')).toBeInTheDocument();
    expect(screen.getByText('Auto (Adaptive)')).toBeInTheDocument();
    expect(screen.getByText('Direct Play (Source)')).toBeInTheDocument();
    expect(screen.getByText('720p')).toBeInTheDocument();
    expect(screen.getByText('480p')).toBeInTheDocument();

    // Check Phase 9 badges
    expect(screen.getByText('Recommended')).toBeInTheDocument();
    expect(screen.getByText('Direct Stream')).toBeInTheDocument();
    expect(screen.getByText('Stream Ready')).toBeInTheDocument();
    expect(screen.getByText('Requires Pre-Transcode')).toBeInTheDocument();
  });

  it('disables Direct Play with clear warning badge when unsupported on browser', () => {
    const onSelect = vi.fn();
    render(
      <QualitySelectorModal
        isOpen={true}
        onClose={vi.fn()}
        qualityLadder={MOCK_LADDER}
        selectedQuality="auto"
        onSelectQuality={onSelect}
        supportsDirectPlay={false}
        directPlayReason="Matroska (.mkv) container cannot be decoded natively by this web browser"
      />,
    );

    const directBtn = screen.getByTestId('quality-opt-source');
    expect(directBtn).toBeDisabled();
    expect(screen.getByText('Unsupported on this browser')).toBeInTheDocument();
    expect(
      screen.getByText('Matroska (.mkv) container cannot be decoded natively by this web browser'),
    ).toBeInTheDocument();

    fireEvent.click(directBtn);
    expect(onSelect).not.toHaveBeenCalled();
  });

  it('disables unready transcode quality options with Requires Pre-Transcode badge', () => {
    const onSelect = vi.fn();
    render(
      <QualitySelectorModal
        isOpen={true}
        onClose={vi.fn()}
        qualityLadder={MOCK_LADDER}
        selectedQuality="auto"
        onSelectQuality={onSelect}
      />,
    );

    const unreadyBtn = screen.getByTestId('quality-opt-480p');
    expect(unreadyBtn).toBeDisabled();
    expect(screen.getByText('Requires Pre-Transcode')).toBeInTheDocument();
    expect(screen.getByText('Quality not pre-transcoded on server')).toBeInTheDocument();

    fireEvent.click(unreadyBtn);
    expect(onSelect).not.toHaveBeenCalled();
  });

  it('calls onSelectQuality and onClose when a ready option is clicked', () => {
    const onSelect = vi.fn();
    const onClose = vi.fn();

    render(
      <QualitySelectorModal
        isOpen={true}
        onClose={onClose}
        qualityLadder={MOCK_LADDER}
        selectedQuality="auto"
        onSelectQuality={onSelect}
      />,
    );

    fireEvent.click(screen.getByTestId('quality-opt-720p'));
    expect(onSelect).toHaveBeenCalledWith('720p', MOCK_LADDER[1]);
    expect(onClose).toHaveBeenCalled();
  });

  it('calls onClose when close button is clicked', () => {
    const onClose = vi.fn();
    render(
      <QualitySelectorModal
        isOpen={true}
        onClose={onClose}
        qualityLadder={MOCK_LADDER}
        selectedQuality="auto"
        onSelectQuality={vi.fn()}
      />,
    );

    fireEvent.click(screen.getByLabelText('Close quality selector'));
    expect(onClose).toHaveBeenCalled();
  });

  it('calls onClose on Escape key press', () => {
    const onClose = vi.fn();
    render(
      <QualitySelectorModal
        isOpen={true}
        onClose={onClose}
        qualityLadder={MOCK_LADDER}
        selectedQuality="720p"
        onSelectQuality={vi.fn()}
      />,
    );

    fireEvent.keyDown(window, { key: 'Escape' });
    expect(onClose).toHaveBeenCalled();
  });
});
