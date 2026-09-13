(() => {
  'use strict';

  const video = document.querySelector('#video');
  const volume = document.querySelector('#volume');
  const mute = document.querySelector('#mute');
  const speed = document.querySelector('#speed');
  if (!video) return;

  const KEYS = {
    volume: 'media_player_volume',
    muted: 'media_player_muted',
    speed: 'media_player_speed',
  };

  const read = (key, fallback) => {
    try {
      const value = localStorage.getItem(key);
      return value === null ? fallback : value;
    } catch (_) {
      return fallback;
    }
  };

  const write = (key, value) => {
    try { localStorage.setItem(key, String(value)); } catch (_) {}
  };

  const validVolume = value => {
    const n = Number(value);
    return Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : 1;
  };

  const validSpeed = value => {
    const n = Number(value);
    if (!Number.isFinite(n)) return 1;
    const option = speed && [...speed.options].find(o => Number(o.value.replace('×', '')) === n);
    return option ? n : 1;
  };

  // Restore preferences before playback starts. The native controls remain the source of truth.
  if (volume) {
    const restoredVolume = validVolume(read(KEYS.volume, volume.value || 1));
    video.volume = restoredVolume;
    volume.value = String(restoredVolume);
  }

  const restoredMuted = read(KEYS.muted, 'false') === 'true';
  video.muted = restoredMuted;

  if (speed) {
    const restoredSpeed = validSpeed(read(KEYS.speed, speed.value || 1));
    video.playbackRate = restoredSpeed;
    speed.value = String(restoredSpeed);
  }

  const syncMuteControl = () => {
    if (mute) mute.setAttribute('aria-pressed', video.muted ? 'true' : 'false');
  };
  syncMuteControl();

  if (volume) {
    volume.addEventListener('input', () => {
      video.volume = validVolume(volume.value);
      video.muted = false;
      write(KEYS.volume, video.volume);
      write(KEYS.muted, false);
      syncMuteControl();
    });
  }

  if (mute) {
    mute.addEventListener('click', () => {
      // player.js toggles muted first; persist the resulting state on the next task turn.
      setTimeout(() => {
        write(KEYS.muted, video.muted);
        if (!video.muted) write(KEYS.volume, video.volume);
        syncMuteControl();
      }, 0);
    });
  }

  if (speed) {
    speed.addEventListener('change', () => {
      const selected = validSpeed(speed.value);
      video.playbackRate = selected;
      speed.value = String(selected);
      write(KEYS.speed, selected);
    });
  }

  // Gesture seeking owns only currentTime. Never alter playbackRate from pointer/touch gestures.
  // This also guards against future gesture code accidentally changing speed.
  const restoreSpeedAfterGesture = () => {
    if (speed) {
      const selected = validSpeed(read(KEYS.speed, speed.value || 1));
      if (video.playbackRate !== selected) video.playbackRate = selected;
      speed.value = String(selected);
    }
  };
  ['pointerup', 'touchend', 'click'].forEach(type => {
    document.querySelector('#shell')?.addEventListener(type, event => {
      if (event.target.closest('#speed')) return;
      restoreSpeedAfterGesture();
    }, { passive: true });
  });

  window.addEventListener('pagehide', () => {
    write(KEYS.volume, video.volume);
    write(KEYS.muted, video.muted);
    write(KEYS.speed, video.playbackRate);
  });
})();
