import { useState, useRef, type ChangeEvent, type DragEvent } from 'react';
import type { SubtitleTrack, SubtitlePrefs } from './useSubtitles';

interface SubtitleSettingsModalProps {
  isOpen: boolean;
  onClose: () => void;
  tracks: SubtitleTrack[];
  activeTrackIndex: number;
  onSelectTrack: (index: number) => void;
  prefs: SubtitlePrefs;
  onUpdatePref: <K extends keyof SubtitlePrefs>(key: K, value: SubtitlePrefs[K]) => void;
  onUploadSubtitle: (file: File) => Promise<{ success: boolean; message: string }>;
}

export function SubtitleSettingsModal({
  isOpen,
  onClose,
  tracks,
  activeTrackIndex,
  onSelectTrack,
  prefs,
  onUpdatePref,
  onUploadSubtitle,
}: SubtitleSettingsModalProps) {
  const [chosenFile, setChosenFile] = useState<File | null>(null);
  const [uploadStatus, setUploadStatus] = useState<{
    text: string;
    type: 'info' | 'success' | 'error';
  } | null>(null);
  const [isUploading, setIsUploading] = useState(false);
  const [isDragging, setIsDragging] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  if (!isOpen) return null;

  const handleFileChange = (e: ChangeEvent<HTMLInputElement>) => {
    if (e.target.files && e.target.files[0]) {
      setChosenFile(e.target.files[0]);
      setUploadStatus(null);
    }
  };

  const handleDragOver = (e: DragEvent<HTMLLabelElement>) => {
    e.preventDefault();
    setIsDragging(true);
  };

  const handleDragLeave = () => {
    setIsDragging(false);
  };

  const handleDrop = (e: DragEvent<HTMLLabelElement>) => {
    e.preventDefault();
    setIsDragging(false);
    if (e.dataTransfer?.files?.[0]) {
      const file = e.dataTransfer.files[0];
      if (file.name.endsWith('.srt') || file.name.endsWith('.vtt')) {
        setChosenFile(file);
        setUploadStatus(null);
      } else {
        setUploadStatus({
          text: '❌ Only .srt and .vtt files are supported',
          type: 'error',
        });
      }
    }
  };

  const handleUpload = async () => {
    if (!chosenFile) return;
    setIsUploading(true);
    setUploadStatus({ text: 'Uploading…', type: 'info' });

    try {
      const result = await onUploadSubtitle(chosenFile);
      if (result.success) {
        setUploadStatus({ text: `✅ ${result.message}`, type: 'success' });
        setChosenFile(null);
        if (fileInputRef.current) fileInputRef.current.value = '';
      } else {
        setUploadStatus({ text: `❌ ${result.message}`, type: 'error' });
      }
    } catch {
      setUploadStatus({
        text: '❌ Upload error. Please try again.',
        type: 'error',
      });
    } finally {
      setIsUploading(false);
    }
  };

  // Preview alignment and placement styles
  const previewBg = `rgba(0,0,0,${prefs.bgOpacity})`;
  const previewVerticalAlign =
    prefs.verticalPos === 'top'
      ? 'flex-start'
      : prefs.verticalPos === 'middle'
      ? 'center'
      : 'flex-end';
  const previewHorizontalAlign =
    prefs.align === 'left'
      ? 'flex-start'
      : prefs.align === 'right'
      ? 'flex-end'
      : 'center';

  return (
    <div
      id="subSettingsModal"
      className="sub-modal"
      onClick={(e) => e.stopPropagation()}
    >
      <div className="sub-modal-content">
        <div className="sub-modal-header">
          <div className="sub-modal-title-wrap">
            <span className="sub-modal-badge">CC</span>
            <span className="modal-title">Subtitle Settings</span>
          </div>
          <button
            id="closeSubModal"
            type="button"
            className="sub-modal-close"
            onClick={onClose}
            aria-label="Close subtitle settings"
          >
            &times;
          </button>
        </div>

        <div className="sub-modal-body">
          {/* Track Selection */}
          <div className="sub-field">
            <label htmlFor="subTrackSelect">Track</label>
            <select
              id="subTrackSelect"
              value={String(activeTrackIndex)}
              onChange={(e) => onSelectTrack(Number(e.target.value))}
            >
              <option value="-1">Subtitles off</option>
              {tracks.map((t, idx) => (
                <option key={t.id || idx} value={String(idx)}>
                  {t.label}
                </option>
              ))}
            </select>
          </div>

          {/* Subtitle File Upload */}
          <div className="sub-field sub-upload-row">
            <label htmlFor="playerSubFileInput">Upload</label>
            <div className="sub-upload-wrap">
              <label
                id="playerSubDropZone"
                className={`sub-drop-zone-mini ${isDragging ? 'sub-drop-over' : ''} ${
                  chosenFile ? 'sub-drop-has-file' : ''
                }`}
                htmlFor="playerSubFileInput"
                tabIndex={0}
                role="button"
                aria-label="Choose or drop subtitle file"
                onDragOver={handleDragOver}
                onDragLeave={handleDragLeave}
                onDrop={handleDrop}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    fileInputRef.current?.click();
                  }
                }}
              >
                <svg
                  viewBox="0 0 24 24"
                  width="15"
                  height="15"
                  fill="currentColor"
                  opacity="0.75"
                  aria-hidden="true"
                >
                  <path d="M9 16h6v-6h4l-7-7-7 7h4zm-4 2h14v2H5z" />
                </svg>
                <span id="playerSubDropLabel">
                  {chosenFile ? chosenFile.name : 'Choose .srt / .vtt'}
                </span>
                <input
                  type="file"
                  id="playerSubFileInput"
                  ref={fileInputRef}
                  accept=".srt,.vtt"
                  style={{ display: 'none' }}
                  aria-hidden="true"
                  onChange={handleFileChange}
                />
              </label>
              {chosenFile && (
                <button
                  type="button"
                  id="playerSubUploadBtn"
                  className="sub-upload-btn-mini"
                  onClick={handleUpload}
                  disabled={isUploading}
                >
                  {isUploading ? '...' : 'Upload'}
                </button>
              )}
            </div>
          </div>

          {/* Upload Status Feedback */}
          {uploadStatus && (
            <div
              id="playerSubStatus"
              className={`sub-status-mini sub-status-${uploadStatus.type}`}
            >
              {uploadStatus.text}
            </div>
          )}

          {/* Text Color */}
          <div className="sub-field">
            <label htmlFor="subColorSelect">Text Color</label>
            <select
              id="subColorSelect"
              value={prefs.color}
              onChange={(e) => onUpdatePref('color', e.target.value)}
            >
              <option value="#ffffff">White</option>
              <option value="#ffff00">Yellow</option>
              <option value="#00e5ff">Cyan</option>
              <option value="#00ff66">Green</option>
              <option value="#ff4081">Magenta</option>
            </select>
          </div>

          {/* Background Opacity */}
          <div className="sub-field">
            <label htmlFor="subBgSelect">Background Opacity</label>
            <select
              id="subBgSelect"
              value={prefs.bgOpacity}
              onChange={(e) => onUpdatePref('bgOpacity', e.target.value)}
            >
              <option value="0">0% (None)</option>
              <option value="0.25">25%</option>
              <option value="0.5">50%</option>
              <option value="0.75">75%</option>
              <option value="1">100% (Solid)</option>
            </select>
          </div>

          {/* Font Size */}
          <div className="sub-field">
            <label htmlFor="subSizeSelect">Font Size</label>
            <select
              id="subSizeSelect"
              value={prefs.size}
              onChange={(e) => onUpdatePref('size', e.target.value)}
            >
              <option value="clamp(17px, 2.1vw, 27px)">75% (Small)</option>
              <option value="clamp(22px, 2.8vw, 36px)">100% (Normal)</option>
              <option value="clamp(28px, 3.5vw, 45px)">125% (Medium)</option>
              <option value="clamp(33px, 4.2vw, 54px)">150% (Large)</option>
              <option value="clamp(44px, 5.6vw, 72px)">200% (Huge)</option>
            </select>
          </div>

          {/* Horizontal Alignment */}
          <div className="sub-field">
            <label htmlFor="subPosSelect">Horizontal Align</label>
            <select
              id="subPosSelect"
              value={prefs.align}
              onChange={(e) => {
                const align = e.target.value as 'left' | 'center' | 'right';
                onUpdatePref('align', align);
                onUpdatePref('pos', align === 'left' ? 20 : align === 'right' ? 80 : 50);
              }}
            >
              <option value="center">Center (Default)</option>
              <option value="left">Left (20%)</option>
              <option value="right">Right (80%)</option>
            </select>
          </div>

          {/* Vertical Position */}
          <div className="sub-field">
            <label htmlFor="subVerticalSelect">Vertical Position</label>
            <select
              id="subVerticalSelect"
              value={prefs.verticalPos}
              onChange={(e) =>
                onUpdatePref(
                  'verticalPos',
                  e.target.value as 'lowered' | 'bottom' | 'raised' | 'middle' | 'top'
                )
              }
            >
              <option value="lowered">Lowered Bottom (Default)</option>
              <option value="bottom">Bottom</option>
              <option value="raised">Raised Bottom</option>
              <option value="middle">Center / Middle</option>
              <option value="top">Top</option>
            </select>
          </div>

          {/* Live Preview Box */}
          <div className="sub-field sub-preview-wrap">
            <label>Preview</label>
            <div
              id="subPreviewBox"
              style={{
                alignItems: previewVerticalAlign,
                justifyContent: previewHorizontalAlign,
              }}
            >
              <span
                id="subPreviewSample"
                style={{
                  color: prefs.color,
                  backgroundColor: previewBg,
                  fontSize: prefs.size,
                  padding: '0.2rem 0.5rem',
                  borderRadius: '3px',
                  textShadow: '0 1px 2px #000, 0 0 3px #000',
                  textAlign: prefs.align,
                }}
              >
                Subtitle preview sample
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
