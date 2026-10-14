export interface ShortcutsModalProps {
  isOpen: boolean;
  onClose: () => void;
}

export function ShortcutsModal({ isOpen, onClose }: ShortcutsModalProps) {
  if (!isOpen) return null;

  return (
    <div
      id="shortcutsModal"
      className="sub-modal shortcuts-modal"
      onClick={(e) => e.stopPropagation()}
      data-testid="shortcuts-modal"
    >
      <div className="sub-modal-content shortcuts-content">
        <div className="sub-modal-header">
          <div className="sub-modal-title-wrap">
            <span className="sub-modal-badge">
              <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor">
                <path d="M20 5H4c-1.1 0-1.99.9-1.99 2L2 17c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm-9 3h2v2h-2V8zm0 3h2v2h-2v-2zM8 8h2v2H8V8zm0 3h2v2H8v-2zm-1 2H5v-2h2v2zm0-3H5V8h2v2zm9 7H8v-2h8v2zm0-4h-2v-2h2v2zm0-3h-2V8h2v2zm3 3h-2v-2h2v2zm0-3h-2V8h2v2z" />
              </svg>
            </span>
            <span className="modal-title">Shortcuts & Gestures</span>
          </div>
          <button
            id="closeShortcutsModal"
            type="button"
            onClick={onClose}
            className="sub-modal-close"
            aria-label="Close shortcuts modal"
          >
            &times;
          </button>
        </div>

        <div className="shortcuts-grid">
          <div className="sc-divider">
            <span>Playback & Navigation</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>Space</kbd> / <kbd>k</kbd>
            </span>
            <span>Play / Pause</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>Home</kbd> / <kbd>0</kbd>
            </span>
            <span>Replay from Start</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>←</kbd> / <kbd>→</kbd>
            </span>
            <span>Seek ±5s</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>j</kbd> / <kbd>l</kbd>
            </span>
            <span>Seek ±10s</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>1</kbd>–<kbd>9</kbd>
            </span>
            <span>Seek 10%–90%</span>
          </div>

          <div className="sc-divider">
            <span>Audio & Screen</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>f</kbd>
            </span>
            <span>Fullscreen</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>m</kbd>
            </span>
            <span>Mute / Unmute</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>↑</kbd> / <kbd>↓</kbd>
            </span>
            <span>Volume ±5%</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>p</kbd> / <kbd>i</kbd>
            </span>
            <span>Picture-in-Picture</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>a</kbd>
            </span>
            <span>Aspect Ratio</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>n</kbd>
            </span>
            <span>Stats for Nerds</span>
          </div>

          <div className="sc-divider">
            <span>Subtitles & Speed</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>c</kbd>
            </span>
            <span>Toggle Subtitles</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>z</kbd> / <kbd>x</kbd>
            </span>
            <span>Subtitle Delay ±50ms</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>&lt;</kbd> / <kbd>&gt;</kbd>
            </span>
            <span>Adjust Speed</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>?</kbd>
            </span>
            <span>Cheat-sheet</span>
          </div>

          <div className="sc-divider">
            <span>Touch & Mobile Gestures</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>Double Tap L/R</kbd>
            </span>
            <span>Seek ±10s</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>Swipe Right Y</kbd>
            </span>
            <span>Volume</span>
          </div>
          <div className="sc-row">
            <span className="sc-keys">
              <kbd>Swipe Left Y</kbd>
            </span>
            <span>Brightness</span>
          </div>
        </div>
      </div>
    </div>
  );
}
