(() => {
  'use strict';

  const video = document.querySelector('#video');
  const volume = document.querySelector('#volume');
  const mute = document.querySelector('#mute');
  const speed = document.querySelector('#speed');
  if (!video) return;

  const read = (key, fallback) => { try { const v = localStorage.getItem(key); return v === null ? fallback : v; } catch (_) { return fallback; } };
  const write = (key, value) => { try { localStorage.setItem(key, String(value)); } catch (_) {} };
  const cookieDevice = () => {
    const match = document.cookie.match(/(?:^|; )ms_device_id=([^;]+)/);
    return match ? decodeURIComponent(match[1]) : '';
  };
  const validVolume = value => { const n = Number(value); return Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : 1; };
  const validSpeed = value => {
    const n = Number(value);
    if (!Number.isFinite(n) || !speed) return 1;
    return [...speed.options].some(o => Number(o.value.replace('×', '')) === n) ? n : 1;
  };

  // localStorage is the client-side source of identity. The cookie is only the transport mirror used by HTTP requests.
  let deviceId = read('media_device_id', '') || cookieDevice();
  if (!deviceId) deviceId = 'dev_' + (crypto.randomUUID ? crypto.randomUUID().replace(/-/g, '') : Date.now().toString(36) + Math.random().toString(36).slice(2));
  write('media_device_id', deviceId);
  try { document.cookie = 'ms_device_id=' + encodeURIComponent(deviceId) + '; Max-Age=31536000; Path=/; SameSite=Lax'; } catch (_) {}

  const movieFilename = (() => {
    const prefix = '/watch/';
    return location.pathname.startsWith(prefix) ? decodeURIComponent(location.pathname.slice(prefix.length)) : '';
  })();
  const prefKey = 'media_player_prefs:v2:' + deviceId;
  const progressKey = 'media_player_progress:v2:' + deviceId + ':' + encodeURIComponent(movieFilename);

  let prefs = {};
  try { prefs = JSON.parse(read(prefKey, '{}')) || {}; } catch (_) { prefs = {}; }
  let localPosition = null;
  try {
    const saved = JSON.parse(read(progressKey, 'null'));
    if (saved && Number.isFinite(Number(saved.position))) localPosition = Math.max(0, Number(saved.position));
  } catch (_) {}

  const savePrefs = () => write(prefKey, JSON.stringify({ version: 2, volume: video.volume, muted: video.muted, speed: video.playbackRate }));
  const syncMuteControl = () => { if (mute) mute.setAttribute('aria-pressed', video.muted ? 'true' : 'false'); };
  let userChangedVolume = false;

  const restorePrefs = () => {
    if (!userChangedVolume && volume) {
      const restoredVolume = validVolume(prefs.volume ?? volume.value ?? 1);
      video.volume = restoredVolume;
      volume.value = String(restoredVolume);
    }
    if (typeof prefs.muted === 'boolean') video.muted = prefs.muted;
    if (speed) {
      const restoredSpeed = validSpeed(prefs.speed ?? speed.value ?? 1);
      video.playbackRate = restoredSpeed;
      speed.value = String(restoredSpeed);
    }
    syncMuteControl();
  };

  restorePrefs();
  ['loadedmetadata', 'canplay', 'play'].forEach(name => video.addEventListener(name, () => setTimeout(restorePrefs, 0), { passive: true }));
  setTimeout(restorePrefs, 100);
  setTimeout(restorePrefs, 500);
  setTimeout(restorePrefs, 1200);

  if (volume) volume.addEventListener('input', () => {
    userChangedVolume = true;
    video.volume = validVolume(volume.value);
    video.muted = false;
    savePrefs();
    syncMuteControl();
  });
  if (mute) mute.addEventListener('click', () => setTimeout(() => { savePrefs(); syncMuteControl(); }, 0));
  video.addEventListener('volumechange', () => { if (userChangedVolume) savePrefs(); }, { passive: true });

  if (speed) speed.addEventListener('change', () => {
    const selected = validSpeed(speed.value);
    video.playbackRate = selected;
    speed.value = String(selected);
    savePrefs();
  });

  // Keep the local copy authoritative for resume state and synchronize it to the server for the same device.
  const savePosition = () => {
    if (!movieFilename || !Number.isFinite(video.currentTime)) return;
    const duration = Number(video.duration) || 0;
    const position = video.ended ? 0 : Math.max(0, video.currentTime);
    write(progressKey, JSON.stringify({ version: 2, position, duration, savedAt: Date.now() }));
  };
  const restorePosition = () => {
    if (!movieFilename || localPosition === null || !Number.isFinite(video.duration) || video.duration <= 0) return;
    if (localPosition > 10 && localPosition < video.duration - 10 && Math.abs(video.currentTime - localPosition) > 1) video.currentTime = Math.min(localPosition, video.duration - 10);
  };
  video.addEventListener('loadedmetadata', () => setTimeout(restorePosition, 0), { passive: true });
  video.addEventListener('durationchange', () => setTimeout(restorePosition, 0), { passive: true });
  video.addEventListener('timeupdate', savePosition, { passive: true });
  video.addEventListener('pause', savePosition, { passive: true });
  video.addEventListener('ended', savePosition, { passive: true });
  window.addEventListener('pagehide', () => { savePrefs(); savePosition(); }, { passive: true });

  // Attach the local device ID to future API requests, even if the server-side cookie was stale before this script ran.
  const nativeFetch = window.fetch.bind(window);
  window.fetch = (input, init = {}) => {
    try {
      const url = typeof input === 'string' ? input : input.url;
      if (url && url.includes('/api/')) {
        const headers = new Headers(init.headers || (input instanceof Request ? input.headers : undefined));
        headers.set('X-Device-Id', deviceId);
        init = { ...init, headers };
      }
    } catch (_) {}
    return nativeFetch(input, init);
  };

  // Gesture seeking owns currentTime only. Never let pointer/touch gestures alter playback speed.
  const restoreSpeedAfterGesture = event => {
    if (event.target.closest && event.target.closest('#speed')) return;
    if (!speed) return;
    let stored = 1;
    try { stored = JSON.parse(read(prefKey, '{}')).speed ?? 1; } catch (_) {}
    const selected = validSpeed(stored);
    if (video.playbackRate !== selected) video.playbackRate = selected;
    speed.value = String(selected);
  };
  ['pointerup', 'touchend', 'click'].forEach(type => document.querySelector('#shell')?.addEventListener(type, restoreSpeedAfterGesture, { passive: true }));
})();
