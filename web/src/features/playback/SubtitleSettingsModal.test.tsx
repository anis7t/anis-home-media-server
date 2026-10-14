import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { SubtitleSettingsModal } from './SubtitleSettingsModal';
import type { SubtitleTrack, SubtitlePrefs } from './useSubtitles';

const MOCK_TRACKS: SubtitleTrack[] = [
  { label: 'English (Local)', lang: 'en', src: '/subtitles/test/test_en.vtt', default: true },
  { label: 'Spanish (Local)', lang: 'es', src: '/subtitles/test/test_es.vtt' },
];

const DEFAULT_PREFS: SubtitlePrefs = {
  enabled: true,
  trackIndex: 0,
  color: '#ffffff',
  bgOpacity: '0.75',
  size: 'clamp(22px, 2.8vw, 36px)',
  align: 'center',
  pos: 50,
  verticalPos: 'lowered',
};

describe('SubtitleSettingsModal', () => {
  it('does not render when closed', () => {
    const { container } = render(
      <SubtitleSettingsModal
        isOpen={false}
        onClose={vi.fn()}
        tracks={MOCK_TRACKS}
        activeTrackIndex={0}
        onSelectTrack={vi.fn()}
        prefs={DEFAULT_PREFS}
        onUpdatePref={vi.fn()}
        onUploadSubtitle={vi.fn()}
      />
    );
    expect(container.querySelector('#subSettingsModal')).toBeNull();
  });

  it('renders all legacy IDs and options when open', () => {
    const { container } = render(
      <SubtitleSettingsModal
        isOpen={true}
        onClose={vi.fn()}
        tracks={MOCK_TRACKS}
        activeTrackIndex={0}
        onSelectTrack={vi.fn()}
        prefs={DEFAULT_PREFS}
        onUpdatePref={vi.fn()}
        onUploadSubtitle={vi.fn()}
      />
    );

    expect(container.querySelector('#subSettingsModal')).toBeInTheDocument();
    expect(container.querySelector('#closeSubModal')).toBeInTheDocument();
    expect(container.querySelector('#subTrackSelect')).toBeInTheDocument();
    expect(container.querySelector('#playerSubDropZone')).toBeInTheDocument();
    expect(container.querySelector('#playerSubFileInput')).toBeInTheDocument();
    expect(container.querySelector('#subColorSelect')).toBeInTheDocument();
    expect(container.querySelector('#subBgSelect')).toBeInTheDocument();
    expect(container.querySelector('#subSizeSelect')).toBeInTheDocument();
    expect(container.querySelector('#subPosSelect')).toBeInTheDocument();
    expect(container.querySelector('#subVerticalSelect')).toBeInTheDocument();
    expect(container.querySelector('#subPreviewBox')).toBeInTheDocument();
    expect(container.querySelector('#subPreviewSample')).toBeInTheDocument();
  });

  it('invokes onSelectTrack when selecting a track', () => {
    const onSelectTrack = vi.fn();
    render(
      <SubtitleSettingsModal
        isOpen={true}
        onClose={vi.fn()}
        tracks={MOCK_TRACKS}
        activeTrackIndex={0}
        onSelectTrack={onSelectTrack}
        prefs={DEFAULT_PREFS}
        onUpdatePref={vi.fn()}
        onUploadSubtitle={vi.fn()}
      />
    );

    const select = screen.getByLabelText('Track') as HTMLSelectElement;
    fireEvent.change(select, { target: { value: '1' } });
    expect(onSelectTrack).toHaveBeenCalledWith(1);

    fireEvent.change(select, { target: { value: '-1' } });
    expect(onSelectTrack).toHaveBeenCalledWith(-1);
  });

  it('invokes onUpdatePref when changing styling options', () => {
    const onUpdatePref = vi.fn();
    render(
      <SubtitleSettingsModal
        isOpen={true}
        onClose={vi.fn()}
        tracks={MOCK_TRACKS}
        activeTrackIndex={0}
        onSelectTrack={vi.fn()}
        prefs={DEFAULT_PREFS}
        onUpdatePref={onUpdatePref}
        onUploadSubtitle={vi.fn()}
      />
    );

    fireEvent.change(screen.getByLabelText('Text Color'), { target: { value: '#ffff00' } });
    expect(onUpdatePref).toHaveBeenCalledWith('color', '#ffff00');

    fireEvent.change(screen.getByLabelText('Background Opacity'), { target: { value: '0.5' } });
    expect(onUpdatePref).toHaveBeenCalledWith('bgOpacity', '0.5');

    fireEvent.change(screen.getByLabelText('Horizontal Align'), { target: { value: 'left' } });
    expect(onUpdatePref).toHaveBeenCalledWith('align', 'left');
    expect(onUpdatePref).toHaveBeenCalledWith('pos', 20);

    fireEvent.change(screen.getByLabelText('Vertical Position'), { target: { value: 'top' } });
    expect(onUpdatePref).toHaveBeenCalledWith('verticalPos', 'top');
  });

  it('handles subtitle file selection and upload flow', async () => {
    const onUploadSubtitle = vi.fn().mockResolvedValue({
      success: true,
      message: 'Uploaded: test_hi_1.srt (Hindi)',
    });

    const { container } = render(
      <SubtitleSettingsModal
        isOpen={true}
        onClose={vi.fn()}
        tracks={MOCK_TRACKS}
        activeTrackIndex={0}
        onSelectTrack={vi.fn()}
        prefs={DEFAULT_PREFS}
        onUpdatePref={vi.fn()}
        onUploadSubtitle={onUploadSubtitle}
      />
    );

    const fileInput = container.querySelector('#playerSubFileInput') as HTMLInputElement;
    const file = new File(['1\n00:00:01,000 --> 00:00:04,000\nNamaste'], 'test_hi_1.srt', {
      type: 'text/plain',
    });

    fireEvent.change(fileInput, { target: { files: [file] } });

    expect(screen.getByText('test_hi_1.srt')).toBeInTheDocument();
    const uploadBtn = container.querySelector('#playerSubUploadBtn') as HTMLButtonElement;
    expect(uploadBtn).toBeInTheDocument();

    fireEvent.click(uploadBtn);
    expect(onUploadSubtitle).toHaveBeenCalledWith(file);

    await waitFor(() => {
      expect(container.querySelector('#playerSubStatus')).toHaveTextContent(
        '✅ Uploaded: test_hi_1.srt (Hindi)'
      );
    });
  });

  it('calls onClose when close button is clicked', () => {
    const onClose = vi.fn();
    const { container } = render(
      <SubtitleSettingsModal
        isOpen={true}
        onClose={onClose}
        tracks={MOCK_TRACKS}
        activeTrackIndex={0}
        onSelectTrack={vi.fn()}
        prefs={DEFAULT_PREFS}
        onUpdatePref={vi.fn()}
        onUploadSubtitle={vi.fn()}
      />
    );

    const closeBtn = container.querySelector('#closeSubModal') as HTMLButtonElement;
    fireEvent.click(closeBtn);
    expect(onClose).toHaveBeenCalled();
  });
});
