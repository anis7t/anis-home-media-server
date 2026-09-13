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

  input.parentNode.insertBefore(wrapper, input);
  wrapper.append(rail, buffered, played, hover, thumb, input);
  if (tooltip) wrapper.appendChild(tooltip);

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

  const renderHover = (event) => {
    const p = pointerPercent(event.clientX);
    hover.style.left = `${p}%`;
    if (tooltip) {
      tooltip.hidden = false;
      tooltip.style.left = `${p}%`;
      tooltip.textContent = fmt((p / 100) * duration());
    }
  };

  const clearHover = () => {
    if (scrubbing) return;
    hover.style.opacity = '0';
    if (tooltip) tooltip.hidden = true;
  };

  const beginScrub = (event) => {
    event.preventDefault();
    scrubbing = true;
    wasPlaying = !video.paused;
    wrapper.classList.add('is-scrubbing');
    wrapper.setPointerCapture?.(event.pointerId);
    renderHover(event);
    setByPointer(event);
  };

  const setByPointer = (event) => {
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

  const finishScrub = (event) => {
    if (!scrubbing) return;
    setByPointer(event);
    scrubbing = false;
    wrapper.classList.remove('is-scrubbing');
    wrapper.releasePointerCapture?.(event.pointerId);
    if (wasPlaying || !video.paused) video.play().catch(() => {});
    clearHover();
  };

  wrapper.addEventListener('pointerdown', beginScrub);
  wrapper.addEventListener('pointermove', (event) => {
    renderHover(event);
    hover.style.opacity = '1';
    if (scrubbing) setByPointer(event);
  });
  wrapper.addEventListener('pointerup', finishScrub);
  wrapper.addEventListener('pointercancel', () => {
    scrubbing = false;
    wrapper.classList.remove('is-scrubbing');
    clearHover();
  });
  wrapper.addEventListener('pointerleave', clearHover);
  wrapper.addEventListener('pointerenter', (event) => {
    hover.style.opacity = '1';
    renderHover(event);
  });

  input.addEventListener('input', () => {
    const p = Number(input.value) || 0;
    setPlayed(p);
  });
  input.addEventListener('focus', () => wrapper.classList.add('is-scrubbing'));
  input.addEventListener('blur', () => {
    if (!scrubbing) wrapper.classList.remove('is-scrubbing');
  });

  const sync = () => {
    if (scrubbing) return;
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
