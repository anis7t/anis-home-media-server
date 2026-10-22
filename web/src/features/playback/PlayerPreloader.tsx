import React from 'react';

export interface PlayerPreloaderProps {
  visible: boolean;
  message?: string;
  onDismiss?: () => void;
}

export const PlayerPreloader: React.FC<PlayerPreloaderProps> = ({
  visible,
  message = 'Initializing player & streams...',
  onDismiss,
}) => {
  return (
    <div
      id="playerPreloader"
      className="player-preloader"
      hidden={!visible}
      style={{ display: visible ? 'flex' : 'none' }}
      onClick={onDismiss}
      role="status"
      aria-live="polite"
    >
      <div className="player-preloader-content" onClick={(e) => e.stopPropagation()}>
        <div className="player-preloader-spinner" role="status" aria-label="Loading" />
        <strong id="playerPreloaderTitle" className="player-preloader-title">
          Loading Media
        </strong>
        <span id="playerPreloaderMsg" className="player-preloader-msg">
          {message}
        </span>
      </div>
    </div>
  );
};
