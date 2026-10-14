import React from 'react';

export interface SeekRipplesProps {
  leftVisible: boolean;
  rightVisible: boolean;
  leftSec?: number;
  rightSec?: number;
}

export const SeekRipples: React.FC<SeekRipplesProps> = ({
  leftVisible,
  rightVisible,
  leftSec = 10,
  rightSec = 10,
}) => {
  return (
    <>
      <div
        id="seekRippleLeft"
        className="seek-ripple seek-ripple-left"
        hidden={!leftVisible}
        style={{ display: leftVisible ? 'flex' : 'none' }}
        aria-hidden={!leftVisible}
      >
        ◀◀ <span id="seekRippleLeftSec">{leftSec}</span>s
      </div>

      <div
        id="seekRippleRight"
        className="seek-ripple seek-ripple-right"
        hidden={!rightVisible}
        style={{ display: rightVisible ? 'flex' : 'none' }}
        aria-hidden={!rightVisible}
      >
        <span id="seekRippleRightSec">{rightSec}</span>s ▶▶
      </div>
    </>
  );
};
