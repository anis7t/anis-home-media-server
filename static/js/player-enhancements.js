(() => {
  'use strict';

  const video = document.querySelector('#video');
  const seek = document.querySelector('#seek');
  const volume = document.querySelector('#volume');
  const mute = document.querySelector('#mute');
  const speed = document.querySelector('#speed');
  if (!video) return;

  // The visual timeline is intentionally slim, but the interactive target is much larger.
  // This matters especially on TV browsers where a native range input may only respond
  // reliably when the pointer lands very close to its rendered track.
  if (seek && !seek.parentElement.classList.contains('seek-hit-area')) {
    const hitArea = document.createElement('div');
    hitArea.className = 'seek-hit-area';
    hitArea.setAttribute('role', 'presentation');
    seek.parentNode.insertBefore(hitArea, seek);
    hitArea.appendChild(seek);

    let pointerSeeking = false;

    const seekFromClientX = clientX => {
      const rect = hitArea.getBoundingClientRect();
      if (!rect.width) return;
      const ratio = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
      const duration = Number(video.duration) || 0;
      if (!duration) return;
      const position = ratio * duration;
      seek.value = String(ratio * 100);
      video.currentTime = position;
      seek.dispatchEvent(new Event('input', { bubbles: true }));
    };

    hitArea.addEventListener('pointerdown', event => {
      if (event.button !== undefined && event.button !== 0) return;
      pointerSeeking = true;
      hitArea.setPointerCapture?.(event.pointerId);
      seekFromClientX(event.clientX);
      event.preventDefault();
    }, { passive: false });

    hitArea.addEventListener('pointermove', event => {
      if (!pointerSeeking) return;
      seekFromClientX(event.clientX);
      event.preventDefault();
    }, { passive: false });

    const stopPointerSeek = event => {
      if (!pointerSeeking) return;
      seekFromClientX(event.clientX);
      pointerSeeking = false;
      if (hitArea.hasPointerCapture?.(event.pointerId)) hitArea.releasePointerCapture(event.pointerId);
      event.preventDefault();
    };
    hitArea.addEventListener('pointerup', stopPointerSeek, { passive: false });
    hitArea.addEventListener('pointercancel', stopPointerSeek, { passive: false });
  }

  const getDeviceId = () => {
    try {
      const stored = localStorage.getItem('media_device_id');
      if (stored) return stored;
    } catch (_) {}
    const match = document.cookie.match(/(?:^|; )ms_device_id=([^;]+)/);
    return match ? decodeURIComponent(match[1]) : '';
  };

  const deviceId = getDeviceId();
  if (!deviceId) return;

  const prefKey = 'media_player_prefs:v2:' + deviceId;
  const cookieKey = 'ms_player_prefs';
  const readPrefs = () => {
    let prefs = {};
    try { prefs = JSON.parse(localStorage.getItem(prefKey) || '{}') || {}; } catch (_) {}
    if (Object.keys(prefs).length) return prefs;
    try {
      const match = document.cookie.match(new RegExp('(?:^|; )' + cookieKey + '=([^;]+)'));
      if (match) prefs = JSON.parse(decodeURIComponent(match[1])) || {};
    } catch (_) {}
    return prefs;
  };
  const writePrefs = prefs => {
    const clean = {
      version: 2,
      volume: Math.min(1, Math.max(0, Number(prefs.volume))),
      muted: Boolean(prefs.muted),
      speed: Number(prefs.speed) || 1,
      savedAt: Date.now()
    };
    try { localStorage.setItem(prefKey, JSON.stringify(clean)); } catch (_) {}
    try {
      document.cookie = cookieKey + '=' + encodeURIComponent(JSON.stringify(clean)) + '; Max-Age=31536000; Path=/; SameSite=Lax';
    } catch (_) {}
  };

  let prefs = readPrefs();
  let userChangedVolume = false;
  let userChangedMute = false;
  let userChangedSpeed = false;

  const allowedSpeed = value => {
    const n = Number(value);
    if (!speed || !Number.isFinite(n)) return 1;
    return [...speed.options].some(o => Math.abs(Number.parseFloat(o.textContent) - n) < 0.001) ? n : 1;
  };

  const restore = () => {
    if (!userChangedVolume && volume && Number.isFinite(Number(prefs.volume))) {
      const val = Math.min(1, Math.max(0, Number(prefs.volume)));
      video.volume = val;
      volume.value = String(val);
    }
    if (!userChangedMute && typeof prefs.muted === 'boolean') video.muted = prefs.muted;
    if (!userChangedSpeed && speed) {
      const val = allowedSpeed(prefs.speed || 1);
      video.playbackRate = val;
      speed.value = [...speed.options].find(o => Math.abs(Number.parseFloat(o.textContent) - val) < 0.001)?.value || speed.value;
    }
    if (mute) mute.setAttribute('aria-pressed', video.muted ? 'true' : 'false');
  };

  restore();
  [100, 500, 1200, 2000].forEach(ms => setTimeout(restore, ms));
  ['loadedmetadata', 'canplay', 'play'].forEach(event => video.addEventListener(event, () => setTimeout(restore, 0), { passive: true }));

  const saveCurrentPrefs = () => {
    prefs = { volume: video.volume, muted: video.muted, speed: video.playbackRate };
    writePrefs(prefs);
    if (mute) mute.setAttribute('aria-pressed', video.muted ? 'true' : 'false');
  };

  if (volume) volume.addEventListener('input', () => {
    userChangedVolume = true;
    video.volume = Math.min(1, Math.max(0, Number(volume.value)));
    video.muted = false;
    userChangedMute = true;
    saveCurrentPrefs();
  });

  if (mute) mute.addEventListener('click', () => {
    setTimeout(() => {
      userChangedMute = true;
      saveCurrentPrefs();
    }, 0);
  });

  if (speed) speed.addEventListener('change', () => {
    setTimeout(() => {
      userChangedSpeed = true;
      const val = allowedSpeed(speed.value);
      video.playbackRate = val;
      saveCurrentPrefs();
    }, 0);
  });

  video.addEventListener('volumechange', () => {
    if (userChangedVolume || userChangedMute) saveCurrentPrefs();
    if (mute) mute.setAttribute('aria-pressed', video.muted ? 'true' : 'false');
  }, { passive: true });

  window.addEventListener('pagehide', saveCurrentPrefs, { passive: true });

  if (seek) {
    const updateSeek = () => {
      const duration = Number(video.duration) || 0;
      const currentTime = Number(video.currentTime) || 0;
      const current = duration ? Math.min(100, Math.max(0, currentTime / duration * 100)) : 0;
      let bufferedEnd = currentTime;

      if (duration && video.buffered && video.buffered.length) {
        try {
          let bestEnd = currentTime;
          let bestDistance = Infinity;
          for (let i = 0; i < video.buffered.length; i++) {
            const start = video.buffered.start(i);
            const end = video.buffered.end(i);
            if (end + 0.25 >= currentTime) {
              const distance = Math.max(0, start - currentTime);
              if (distance < bestDistance || (distance === bestDistance && end > bestEnd)) {
                bestDistance = distance;
                bestEnd = end;
              }
            }
          }
          bufferedEnd = Math.max(currentTime, bestEnd);
        } catch (_) {}
      }

      const buffered = duration ? Math.min(100, Math.max(current, bufferedEnd / duration * 100)) : current;
      seek.style.setProperty('--seek-pct', current + '%');
      seek.style.setProperty('--buffer-pct', buffered + '%');
    };
    ['loadedmetadata', 'durationchange', 'progress', 'timeupdate', 'canplay', 'playing', 'waiting', 'seeking', 'seeked'].forEach(event => video.addEventListener(event, updateSeek, { passive: true }));
    seek.addEventListener('input', updateSeek, { passive: true });
    updateSeek();
  }
})();
