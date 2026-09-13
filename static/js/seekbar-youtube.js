(() => {
  'use strict';

  const video = document.querySelector('#video');
  const input = document.querySelector('#seek');
  const controls = document.querySelector('#controls');
  if (!video || !input || !controls || document.querySelector('#seekTrack')) return;

  const tooltip = document.querySelector('#seekTooltip');
  const wrapper = document.createElement('div');
  wrapper.id = 'seekTrack';
  wrapper.className = 'seek-track';
  wrapper.setAttribute('role', 'presentation');

  const rail = document.createElement('span'); rail.className = 'seek-rail'; rail.setAttribute('aria-hidden', 'true');
  const buffered = document.createElement('span'); buffered.id = 'seekBuffered'; buffered.className = 'seek-buffered'; buffered.setAttribute('aria-hidden', 'true');
  const played = document.createElement('span'); played.id = 'seekPlayed'; played.className = 'seek-played'; played.setAttribute('aria-hidden', 'true');
  const hover = document.createElement('span'); hover.id = 'seekHoverMarker'; hover.className = 'seek-hover-marker'; hover.setAttribute('aria-hidden', 'true');
  const thumb = document.createElement('span'); thumb.id = 'seekThumb'; thumb.className = 'seek-thumb'; thumb.setAttribute('aria-hidden', 'true');

  input.parentNode.insertBefore(wrapper, input);
  wrapper.append(rail, buffered, played, hover, thumb, input);
  if (tooltip) wrapper.appendChild(tooltip);

  const preview = document.createElement('div');
  preview.id = 'seekPreview';
  preview.className = 'seek-preview';
  preview.hidden = true;
  preview.setAttribute('aria-hidden', 'true');
  const previewImage = document.createElement('img');
  previewImage.alt = '';
  previewImage.loading = 'eager';
  previewImage.decoding = 'async';
  const previewMissing = document.createElement('div');
  previewMissing.className = 'seek-preview-missing';
  previewMissing.textContent = 'Generating preview…';
  const previewTime = document.createElement('div');
  previewTime.className = 'seek-preview-time';
  preview.append(previewImage, previewMissing, previewTime);
  wrapper.appendChild(preview);

  input.setAttribute('aria-label', 'Seek');
  input.setAttribute('aria-valuemin', '0');
  input.setAttribute('aria-valuemax', '100');
  input.setAttribute('aria-valuenow', input.value || '0');

  const duration = () => {
    const d = Number(window.timelineDuration?.() ?? video.duration);
    return Number.isFinite(d) && d > 0 ? d : 0;
  };

  const fmt = (seconds) => {
    const s = Math.max(0, Math.floor(Number(seconds) || 0));
    return (s > 3599 ? `${Math.floor(s / 3600)}:` : '') +
      String(Math.floor((s % 3600) / 60)).padStart(s > 3599 ? 2 : 1, '0') + ':' + String(s % 60).padStart(2, '0');
  };

  const setPlayed = (pct) => {
    const p = Math.max(0, Math.min(100, Number(pct) || 0));
    played.style.width = `${p}%`;
    thumb.style.left = `${p}%`;
    input.style.setProperty('--seek-pct', `${p}%`);
    input.setAttribute('aria-valuenow', p.toFixed(2));
    return p;
  };

  const renderBuffered = () => {
    const d = duration();
    buffered.replaceChildren();
    if (!d) return;
    try {
      const ranges = video.buffered;
      for (let i = 0; i < ranges.length; i += 1) {
        const start = Math.max(0, Math.min(d, Number(ranges.start(i))));
        const end = Math.max(start, Math.min(d, Number(ranges.end(i))));
        if (!(end > start)) continue;
        const segment = document.createElement('i');
        segment.style.left = `${(start / d) * 100}%`;
        segment.style.width = `${((end - start) / d) * 100}%`;
        buffered.appendChild(segment);
      }
    } catch (_) {}
  };

  const pointerPercent = (clientX) => {
    const rect = wrapper.getBoundingClientRect();
    return Math.max(0, Math.min(100, ((clientX - rect.left) / Math.max(rect.width, 1)) * 100));
  };

  const source = document.querySelector('#source');
  const mediaFilename = (() => {
    if (!source?.src) return '';
    try {
      const url = new URL(source.src, location.origin);
      if (!url.pathname.startsWith('/media/')) return '';
      return decodeURIComponent(url.pathname.slice('/media/'.length));
    } catch (_) {
      return '';
    }
  })();

  const previewCache = new Map();
  let previewMetaPromise = null;
  let scrubbing = false;
  let wasPlaying = false;
  let hoverRaf = 0;
  let lastHoverX = null;

  const loadPreviewMeta = () => {
    if (!mediaFilename) return Promise.resolve(null);
    if (!previewMetaPromise) {
      previewMetaPromise = fetch(`/api/seek-preview-meta/${encodeURIComponent(mediaFilename).replace(/%2F/g, '/')}`, { cache: 'no-store' })
        .then(r => r.ok ? r.json() : null)
        .catch(() => null);
    }
    return previewMetaPromise;
  };

  const renderHover = (event) => {
    const d = duration();
    if (!d) return;
    lastHoverX = event.clientX;
    if (hoverRaf) return;
    hoverRaf = requestAnimationFrame(async () => {
      hoverRaf = 0;
      if (lastHoverX == null) return;
      const p = pointerPercent(lastHoverX);
      const target = (p / 100) * d;
      hover.style.left = `${p}%`;
      hover.style.opacity = '1';
      preview.style.left = `${p}%`;
      preview.hidden = false;
      previewTime.textContent = fmt(target);
      if (tooltip) tooltip.hidden = true;

      const meta = await loadPreviewMeta();
      if (!meta || !meta.interval || !meta.count || !meta.base_url) {
        previewImage.hidden = true;
        previewMissing.hidden = false;
        return;
      }
      const idx = Math.max(0, Math.min(meta.count - 1, Math.floor(target / meta.interval)));
      const url = `${meta.base_url}/thumb_${String(idx).padStart(5, '0')}.jpg`;
      if (previewCache.get('idx') !== idx) {
        previewCache.set('idx', idx);
        previewImage.onload = () => { previewMissing.hidden = true; previewImage.hidden = false; };
        previewImage.onerror = () => { previewImage.hidden = true; previewMissing.hidden = false; };
        previewImage.src = url;
      } else if (previewImage.complete && previewImage.naturalWidth) {
        previewMissing.hidden = true;
        previewImage.hidden = false;
      }
    });
  };

  const clearHover = () => {
    if (scrubbing) return;
    hover.style.opacity = '0';
    preview.hidden = true;
    if (tooltip) tooltip.hidden = true;
  };

  const seekToEvent = (event) => {
    const d = duration();
    if (!d) return;
    const p = pointerPercent(event.clientX);
    const target = (p / 100) * d;
    input.value = p;
    setPlayed(p);
    video.currentTime = target;
    if (typeof window.checkPreparing === 'function') window.checkPreparing(target);
    const timeElapsed = document.querySelector('#timeElapsed');
    const timeTotal = document.querySelector('#timeTotal');
    const time = document.querySelector('#time');
    if (timeElapsed) timeElapsed.textContent = fmt(target);
    if (timeTotal) timeTotal.textContent = fmt(d);
    if (time) time.textContent = `${fmt(target)} / ${fmt(d)}`;
  };

  const beginScrub = (event) => {
    if (event.pointerType === 'mouse' && event.button !== 0) return;
    event.preventDefault();
    event.stopPropagation();
    scrubbing = true;
    wasPlaying = !video.paused;
    wrapper.classList.add('is-scrubbing');
    wrapper.setPointerCapture?.(event.pointerId);
    seekToEvent(event);
    renderHover(event);
  };

  const finishScrub = (event) => {
    if (!scrubbing) return;
    event.preventDefault();
    event.stopPropagation();
    seekToEvent(event);
    scrubbing = false;
    wrapper.classList.remove('is-scrubbing');
    wrapper.releasePointerCapture?.(event.pointerId);
    if (wasPlaying) video.play().catch(() => {});
    renderBuffered();
  };

  wrapper.addEventListener('pointerdown', beginScrub);
  wrapper.addEventListener('pointermove', (event) => {
    renderHover(event);
    if (scrubbing) seekToEvent(event);
  });
  wrapper.addEventListener('pointerup', finishScrub);
  wrapper.addEventListener('pointercancel', (event) => {
    event.stopPropagation();
    scrubbing = false;
    wrapper.classList.remove('is-scrubbing');
    clearHover();
  });
  wrapper.addEventListener('pointerleave', clearHover);
  wrapper.addEventListener('pointerenter', renderHover);

  input.addEventListener('input', () => setPlayed(Number(input.value) || 0));
  input.addEventListener('change', renderBuffered);
  input.addEventListener('focus', () => wrapper.classList.add('is-scrubbing'));
  input.addEventListener('blur', () => { if (!scrubbing) wrapper.classList.remove('is-scrubbing'); });

  const sync = () => {
    if (scrubbing) return;
    const d = duration();
    setPlayed(d ? (video.currentTime / d) * 100 : 0);
    renderBuffered();
  };

  ['loadedmetadata', 'durationchange', 'progress', 'loadeddata', 'canplay', 'playing', 'seeking', 'seeked', 'stalled', 'emptied', 'waiting', 'timeupdate'].forEach((eventName) => {
    video.addEventListener(eventName, sync);
  });

  setInterval(renderBuffered, 500);
  renderBuffered();
  sync();
})();
