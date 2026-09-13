(() => {
  'use strict';

  const prefix = '/movie/';
  if (!location.pathname.startsWith(prefix)) return;
  const filename = decodeURIComponent(location.pathname.slice(prefix.length));
  if (!filename) return;

  const getDeviceId = () => {
    try {
      const stored = localStorage.getItem('media_device_id');
      if (stored) return stored;
    } catch (_) {}
    const match = document.cookie.match(/(?:^|; )ms_device_id=([^;]+)/);
    return match ? decodeURIComponent(match[1]) : '';
  };

  const formatTime = seconds => {
    const total = Math.max(0, Math.floor(Number(seconds) || 0));
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = String(total % 60).padStart(2, '0');
    return h ? `${h}:${String(m).padStart(2, '0')}:${s}` : `${m}:${s}`;
  };

  const refreshProgress = async () => {
    try {
      const headers = {};
      const deviceId = getDeviceId();
      if (deviceId) headers['X-Device-Id'] = deviceId;
      const response = await fetch(`/api/progress?filename=${encodeURIComponent(filename)}`, {
        cache: 'no-store',
        headers,
      });
      if (!response.ok) return;
      const progress = await response.json();
      const position = Math.max(0, Number(progress.position) || 0);
      const duration = Math.max(0, Number(progress.duration) || 0);
      const percent = duration ? Math.min(100, position / duration * 100) : 0;
      const resumeable = position > 10 && (!duration || position < duration - 10);

      const playBtn = document.querySelector('#playBtn');
      const status = document.querySelector('#watchStatusBadge');
      const endsAt = document.querySelector('#endsAtBadge');
      const toggleBtn = document.querySelector('#watchToggleBtn');

      if (playBtn) {
        if (resumeable) {
          playBtn.textContent = `▶ Resume (${formatTime(position)})`;
        } else {
          playBtn.textContent = '▶ Play';
        }
      }

      if (status) {
        if (percent >= 90) {
          status.className = 'badge-status status-watched';
          status.textContent = 'Watched ✓';
        } else if (resumeable) {
          status.className = 'badge-status status-progress';
          status.textContent = `In Progress (${Math.round(percent)}%)`;
        } else {
          status.className = 'badge-status status-unwatched';
          status.textContent = 'Unwatched';
        }
      }

      if (toggleBtn) toggleBtn.textContent = percent >= 90 ? 'Mark Unwatched' : '✓ Mark Watched';

      if (endsAt) {
        if (duration && duration > position + 60) {
          const end = new Date(Date.now() + (duration - position) * 1000);
          let hours = end.getHours();
          const minutes = String(end.getMinutes()).padStart(2, '0');
          const ampm = hours >= 12 ? 'PM' : 'AM';
          hours = hours % 12 || 12;
          endsAt.textContent = `Ends at ${hours}:${minutes} ${ampm}`;
          endsAt.style.display = 'inline-flex';
        } else {
          endsAt.textContent = '';
          endsAt.style.display = 'none';
        }
      }
    } catch (_) {}
  };

  refreshProgress();
  window.addEventListener('pageshow', refreshProgress);
  window.addEventListener('focus', refreshProgress);
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) refreshProgress();
  });
})();
