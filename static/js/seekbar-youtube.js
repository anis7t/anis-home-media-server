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

  const rail = document.createElement('span');
  rail.className = 'seek-rail';
  rail.setAttribute('aria-hidden', 'true');

  const buffered = document.createElement('span');
  buffered.id = 'seekBuffered';
  buffered.className = 'seek-buffered';
  buffered.setAttribute('aria-hidden', 'true');

  const played = document.createElement('span');
  played.id = 'seekPlayed';
  played.className = 'seek-played';
  played.setAttribute('aria-hidden', 'true');

  const hover = document.createElement('span');
  hover.id = 'seekHoverMarker';
  hover.className = 'seek-hover-marker';
  hover.setAttribute('aria-hidden', 'true');

  const thumb = document.createElement('span');
  thumb.id = 'seekThumb';
  thumb.className = 'seek-thumb';
  thumb.setAttribute('aria-hidden', 'true');

  const preview = document.createElement('div');
  preview.className = 'seek-preview';
  preview.hidden = true;

  const previewImage = document.createElement('img');
  previewImage.className = 'seek-preview-image';
  previewImage.alt = '';
  previewImage.decoding = 'async';
  previewImage.hidden = true;

  const previewMissing = document.createElement('div');
  previewMissing.className = 'seek-preview-missing';
  previewMissing.textContent = 'Generating preview…';
  const previewSpinner = document.createElement('div');
  previewSpinner.className = 'seek-preview-spinner-wrap';
  previewSpinner.setAttribute('role', 'status');
  previewSpinner.setAttribute('aria-label', 'Loading preview');
  previewSpinner.innerHTML = '<span class="seek-preview-spinner"></span>';

  const previewTime = document.createElement('div');
  previewTime.className = 'seek-preview-time';

  preview.append(previewImage, previewMissing, previewTime);
  preview.append(previewImage, previewSpinner, previewTime);

  input.parentNode.insertBefore(wrapper, input);
  wrapper.append(rail, buffered, played, hover, thumb, input, preview);
  if (tooltip) wrapper.appendChild(tooltip);

  input.setAttribute('aria-label', 'Seek');
  input.setAttribute('aria-valuemin', '0');
  input.setAttribute('aria-valuemax', '100');
  input.setAttribute('aria-valuenow', input.value || '0');

  const getMediaFilename = () => {
    if (window.mediaFilename) return window.mediaFilename;
    if (video.dataset && video.dataset.filename) return video.dataset.filename;
    const match = window.location.pathname.match(/^\/watch\/(.+)$/);
    if (match) return decodeURIComponent(match[1]);
    return null;
  };

  let previewMeta = null;
  let previewMetaPromise = null;
  let previewMetaFailed = false;

  const loadPreviewMeta = () => {
    if (previewMeta) return Promise.resolve(previewMeta);
    if (previewMetaFailed) return Promise.resolve(null);
    if (previewMetaPromise) return previewMetaPromise;
    const fn = getMediaFilename();
    if (!fn) return Promise.resolve(null);

    const encodedPath = fn.split('/').map(encodeURIComponent).join('/');
    previewMetaPromise = fetch(`/api/seek-preview-meta/${encodedPath}`)
      .then((r) => {
        if (!r.ok) throw new Error('Preview meta not available');
        return r.json();
      })
      .then((data) => {
        previewMeta = data;
        return data;
      })
      .catch(() => {
        previewMetaPromise = null;
        setTimeout(() => { previewMetaFailed = false; }, 2000);
        return null;
      });
    return previewMetaPromise;
  };

  // Preload metadata early
  loadPreviewMeta();

  const duration = () => {
    const d = Number(window.timelineDuration?.() ?? video.duration);
    return Number.isFinite(d) && d > 0 ? d : 0;
  };

  const fmt = (seconds) => {
    const s = Math.max(0, Math.floor(Number(seconds) || 0));
    return (s > 3599 ? `${Math.floor(s / 3600)}:` : '') +
      String(Math.floor((s % 3600) / 60)).padStart(s > 3599 ? 2 : 1, '0') + ':' +
      String(s % 60).padStart(2, '0');
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
    buffered.textContent = '';
    if (!d) return;
    try {
      for (let i = 0; i < video.buffered.length; i += 1) {
        const start = Math.max(0, Math.min(d, video.buffered.start(i)));
        const end = Math.max(start, Math.min(d, video.buffered.end(i)));
        if (end <= start) continue;
        const segment = document.createElement('i');
        segment.style.left = `${(start / d) * 100}%`;
        segment.style.width = `${((end - start) / d) * 100}%`;
        buffered.appendChild(segment);
      }
    } catch (_) {
      // Media TimeRanges can briefly become unavailable during source changes.
    }
  };

  const pointerPercent = (clientX) => {
    const rect = wrapper.getBoundingClientRect();
    return Math.max(0, Math.min(100, ((clientX - rect.left) / Math.max(rect.width, 1)) * 100));
  };

  let scrubbing = false;
  let wasPlaying = false;
  let activePreviewUrl = '';
  let previewDebounceTimer = null;
  const imageCache = new Set();

  const updatePreviewThumbnail = (targetSeconds) => {
    if (!previewMeta || !previewMeta.count || !previewMeta.interval) {
      if (!previewImage.src) {
        previewMissing.hidden = false;
        previewImage.hidden = true;
      }
      previewImage.hidden = true;
      previewSpinner.hidden = false;
      previewSpinner.innerHTML = '<span class="seek-preview-spinner"></span>';
      loadPreviewMeta().then((meta) => {
        if (meta && !preview.hidden) updatePreviewThumbnail(targetSeconds);
      });
      return;
    }

    const fn = getMediaFilename();
    if (!fn) return;

    const thumbIndex = Math.max(
      0,
      Math.min(previewMeta.count - 1, Math.floor(targetSeconds / previewMeta.interval))
    );
    const thumbName = `thumb_${String(thumbIndex).padStart(5, '0')}.jpg`;
    const encodedPath = fn.split('/').map(encodeURIComponent).join('/');
    const url = `/seek-preview/${encodedPath}/${thumbName}`;

    if (activePreviewUrl === url && previewImage.src.endsWith(thumbName) && !previewImage.hidden) {
      return;
    }
    activePreviewUrl = url;

    if (imageCache.has(url)) {
      clearTimeout(previewDebounceTimer);
      previewImage.src = url;
      previewImage.hidden = false;
      previewSpinner.hidden = true;
      return;
    }

    // Immediately hide previous preview frame and display soft spinner
    previewImage.hidden = true;
    previewSpinner.hidden = false;
    previewSpinner.innerHTML = '<span class="seek-preview-spinner"></span>';

    clearTimeout(previewDebounceTimer);
    previewDebounceTimer = setTimeout(() => {
      const img = new Image();
      img.decoding = 'async';
      img.onload = () => {
        if (activePreviewUrl !== url) return;
        imageCache.add(url);
        previewImage.src = url;
        previewImage.hidden = false;
        previewMissing.hidden = true;
        previewSpinner.hidden = true;
      };
      img.onerror = () => {
        if (activePreviewUrl !== url) return;
        if (!previewImage.src) {
          previewMissing.textContent = 'Preview unavailable';
          previewMissing.hidden = false;
          previewImage.hidden = true;
        }
        previewImage.hidden = true;
        previewSpinner.hidden = false;
        previewSpinner.innerHTML = '<span class="seek-preview-fallback">Unavailable</span>';
      };
      img.src = url;
    }, 35);
  };

  const renderHover = (event) => {
    const rect = wrapper.getBoundingClientRect();
    const p = Math.max(0, Math.min(100, ((event.clientX - rect.left) / Math.max(rect.width, 1)) * 100));
    hover.style.left = `${p}%`;

    const d = duration();
    const targetSeconds = (p / 100) * d;

    // Edge-clamped horizontal positioning for preview card
    const pointerX = event.clientX - rect.left;
    const previewWidth = preview.offsetWidth || (window.innerWidth <= 768 ? 180 : 220);
    const halfWidth = previewWidth / 2;
    const clampedX = Math.max(halfWidth + 4, Math.min(rect.width - halfWidth - 4, pointerX));
    preview.style.left = `${clampedX}px`;
    previewTime.textContent = fmt(targetSeconds);
    preview.hidden = false;

    if (tooltip) {
      tooltip.hidden = true; // Use preview card with timestamp instead of redundant tooltip
      tooltip.style.left = `${p}%`;
      tooltip.textContent = fmt(targetSeconds);
    }

    updatePreviewThumbnail(targetSeconds);
  };

  const clearHover = () => {
    if (scrubbing) return;
    hover.style.opacity = '0';
    if (tooltip) tooltip.hidden = true;
    preview.hidden = true;
    previewImage.hidden = true;
    previewSpinner.hidden = true;
    activePreviewUrl = '';
    clearTimeout(previewDebounceTimer);
  };

  const updateScrubVisual = (event) => {
    const d = duration();
    if (!d) return null;
    const p = pointerPercent(event.clientX);
    const target = (p / 100) * d;
    input.value = p;
    setPlayed(p);
    window.isScrubbing = true;

    // Synchronize time display with player.html
    if (typeof window.updateTimeDisplay === 'function') {
      window.updateTimeDisplay(target, d);
    } else {
      const timeElapsed = document.querySelector('#timeElapsed');
      const timeTotal = document.querySelector('#timeTotal');
      const time = document.querySelector('#time');
      if (timeElapsed) timeElapsed.textContent = fmt(target);
      if (timeTotal) timeTotal.textContent = fmt(d);
      if (time) time.textContent = `${fmt(target)} / ${fmt(d)}`;
    }
    return target;
  };

  const commitSeek = (event) => {
    const d = duration();
    if (!d) return;
    const p = pointerPercent(event.clientX);
    const target = (p / 100) * d;
    video.currentTime = target;
    if (typeof window.checkPreparing === 'function') window.checkPreparing(target);
  };

  const beginScrub = (event) => {
    if (event.button !== undefined && event.button !== 0) return;
    event.preventDefault();
    scrubbing = true;
    window.isScrubbing = true;
    wasPlaying = !video.paused;
    wrapper.classList.add('is-scrubbing');
    if (event.pointerId) wrapper.setPointerCapture?.(event.pointerId);
    renderHover(event);
    updateScrubVisual(event);
  };

  const finishScrub = (event) => {
    if (!scrubbing) return;
    updateScrubVisual(event);
    commitSeek(event);
    scrubbing = false;
    window.isScrubbing = false;
    wrapper.classList.remove('is-scrubbing');
    if (event.pointerId) wrapper.releasePointerCapture?.(event.pointerId);
    if (wasPlaying || !video.paused) video.play().catch(() => { });
    clearHover();
  };

  const keepControlsVisible = () => {
    const s = document.querySelector('#shell');
    if (s) s.classList.add('show');
  };

  let lastMove = null;
  const onMove = (event) => {
    keepControlsVisible();
    if (lastMove && lastMove.clientX === event.clientX && lastMove.clientY === event.clientY && (event.timeStamp - lastMove.timeStamp < 20)) {
      return;
    }
    lastMove = event;
    renderHover(event);
    hover.style.opacity = '1';
    if (scrubbing) updateScrubVisual(event);
  };

  const onEnter = (event) => {
    keepControlsVisible();
    hover.style.opacity = '1';
    renderHover(event);
  };

  const onLeave = (event) => {
    if (event && event.relatedTarget && wrapper.contains(event.relatedTarget)) {
      return;
    }
    clearHover();
  };

  wrapper.addEventListener('pointermove', onMove);
  wrapper.addEventListener('mousemove', onMove);
  wrapper.addEventListener('pointerenter', onEnter);
  wrapper.addEventListener('mouseenter', onEnter);
  wrapper.addEventListener('pointerleave', onLeave);
  wrapper.addEventListener('mouseleave', onLeave);

  wrapper.addEventListener('pointerdown', beginScrub);
  wrapper.addEventListener('mousedown', beginScrub);
  wrapper.addEventListener('pointerup', finishScrub);
  wrapper.addEventListener('mouseup', finishScrub);
  wrapper.addEventListener('pointercancel', () => {
    scrubbing = false;
    window.isScrubbing = false;
    wrapper.classList.remove('is-scrubbing');
    clearHover();
  });

  window.addEventListener('pointerup', (event) => {
    if (scrubbing) finishScrub(event);
  });
  window.addEventListener('mouseup', (event) => {
    if (scrubbing) finishScrub(event);
  });
  window.addEventListener('pointercancel', () => {
    if (scrubbing) {
      scrubbing = false;
      window.isScrubbing = false;
      wrapper.classList.remove('is-scrubbing');
      clearHover();
    }
  });

  input.addEventListener('input', () => {
    const p = Number(input.value) || 0;
    setPlayed(p);
    const d = duration();
    if (d && typeof window.updateTimeDisplay === 'function') {
      window.updateTimeDisplay((p / 100) * d, d);
    }
  });
  input.addEventListener('focus', () => wrapper.classList.add('is-scrubbing'));
  input.addEventListener('blur', () => {
    if (!scrubbing) wrapper.classList.remove('is-scrubbing');
  });

  const sync = () => {
    if (scrubbing || window.isScrubbing || video.seeking) return;
    const d = duration();
    setPlayed(d ? (video.currentTime / d) * 100 : 0);
  };

  ['loadedmetadata', 'durationchange', 'progress', 'loadeddata', 'canplay', 'playing', 'seeking', 'seeked', 'stalled', 'emptied'].forEach((eventName) => {
    video.addEventListener(eventName, () => {
      renderBuffered();
      sync();
    });
  });
  video.addEventListener('timeupdate', sync);

  renderBuffered();
  sync();
})();
