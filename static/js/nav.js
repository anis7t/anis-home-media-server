/**
 * Navigation Transitions & Progress Indicator
 * Provides instant visual feedback and smooth transitions across media server views.
 */
(function() {
  'use strict';

  let progressBar = null;
  let progressFill = null;
  let progressTimer = null;
  let finishTimer = null;

  function createProgressBar() {
    if (progressBar && document.body && document.body.contains(progressBar)) return;
    if (!document.body) return;
    progressBar = document.getElementById('navProgressBar');
    if (!progressBar) {
      progressBar = document.createElement('div');
      progressBar.id = 'navProgressBar';
      progressBar.className = 'nav-progress-bar';
      progressBar.setAttribute('aria-hidden', 'true');
      progressFill = document.createElement('div');
      progressFill.className = 'nav-progress-fill';
      progressBar.appendChild(progressFill);
      document.body.appendChild(progressBar);
    } else {
      progressFill = progressBar.querySelector('.nav-progress-fill') || progressBar;
    }
  }

  function startProgress() {
    createProgressBar();
    if (!progressBar || !progressFill) return;
    clearTimeout(progressTimer);
    clearTimeout(finishTimer);
    progressBar.classList.remove('finish', 'fade-out');
    progressBar.classList.add('active');
    progressFill.style.transition = 'none';
    progressFill.style.width = '0%';
    progressBar.style.opacity = '1';
    void progressBar.offsetWidth;
    progressFill.style.transition = 'width 140ms cubic-bezier(0.1, 0.9, 0.2, 1)';
    progressFill.style.width = '32%';
    progressTimer = setTimeout(() => {
      progressFill.style.transition = 'width 1.8s cubic-bezier(0.08, 0.8, 0.15, 1)';
      progressFill.style.width = '82%';
    }, 150);
    document.body.classList.add('page-navigating');
  }

  function finishProgress() {
    if (!progressBar || !progressFill) return;
    clearTimeout(progressTimer);
    clearTimeout(finishTimer);
    progressFill.style.transition = 'width 160ms ease-out';
    progressFill.style.width = '100%';
    progressBar.classList.add('finish');
    finishTimer = setTimeout(() => {
      progressBar.classList.add('fade-out');
      document.body.classList.remove('page-navigating');
      setTimeout(() => {
        progressBar.classList.remove('active', 'finish', 'fade-out');
        progressFill.style.width = '0%';
      }, 250);
    }, 180);
  }

  function resetProgress() {
    clearTimeout(progressTimer);
    clearTimeout(finishTimer);
    if (document.body) document.body.classList.remove('page-navigating');
    if (progressBar && progressFill) {
      progressBar.classList.remove('active', 'finish', 'fade-out');
      progressFill.style.transition = 'none';
      progressFill.style.width = '0%';
    }
  }

  function isInternalLink(a) {
    if (!a || !a.href) return false;
    if (a.hasAttribute('download') || a.getAttribute('target') === '_blank') return false;
    if (a.getAttribute('rel') === 'external' || a.dataset.noTransition !== undefined) return false;
    if (a.protocol !== 'http:' && a.protocol !== 'https:') return false;
    if (a.origin !== window.location.origin) return false;
    if (a.pathname === window.location.pathname && a.search === window.location.search && a.hash) return false;
    return true;
  }

  document.addEventListener('click', function(e) {
    if (e.defaultPrevented || e.button !== 0) return;
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const link = e.target.closest('a');
    if (!link || !isInternalLink(link)) return;
    startProgress();
  }, { capture: true, passive: true });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => {
      createProgressBar();
      finishProgress();
    });
  } else {
    createProgressBar();
    finishProgress();
  }

  window.addEventListener('pageshow', function(e) {
    if (e.persisted) resetProgress();
    else finishProgress();
  });

  window.NavTransitions = {
    start: startProgress,
    finish: finishProgress,
    reset: resetProgress
  };
})();

// Large-file upload override. manage.html defines the upload modal first; this script
// replaces its single-request implementation with resumable 8 MiB POST requests.
if (document.getElementById('uploadModal') && typeof startUpload === 'function') {
  const LARGE_UPLOAD_CHUNK_SIZE = 8 * 1024 * 1024;
  let chunkUploadId = null;
  let chunkUploadCancelled = false;

  function abortChunkUploadSession() {
    chunkUploadCancelled = true;
    if (!chunkUploadId) return;
    const id = chunkUploadId;
    chunkUploadId = null;
    fetch('/api/upload/chunk/' + encodeURIComponent(id), { method: 'DELETE', keepalive: true }).catch(() => {});
  }

  function xhrUploadChunk(url, blob, offset, onProgress) {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      uploadXHR = xhr;
      xhr.open('POST', url);
      xhr.setRequestHeader('Content-Type', 'application/octet-stream');
      xhr.setRequestHeader('X-Upload-Offset', String(offset));
      xhr.upload.addEventListener('progress', e => {
        if (e.lengthComputable && onProgress) onProgress(e.loaded);
      });
      xhr.addEventListener('load', () => {
        uploadXHR = null;
        if (xhr.status >= 200 && xhr.status < 300) {
          try { resolve(JSON.parse(xhr.responseText)); }
          catch (_) { reject(new Error('Invalid server response.')); }
        } else {
          let message = 'Upload chunk failed (' + xhr.status + ')';
          try { const data = JSON.parse(xhr.responseText); if (data.error) message = data.error; } catch (_) {}
          const error = new Error(message);
          error.status = xhr.status;
          try { error.currentOffset = JSON.parse(xhr.responseText).current_offset; } catch (_) {}
          reject(error);
        }
      });
      xhr.addEventListener('error', () => {
        uploadXHR = null;
        reject(new Error('Network connection error during upload chunk.'));
      });
      xhr.addEventListener('abort', () => {
        uploadXHR = null;
        reject(new Error('Upload aborted.'));
      });
      xhr.send(blob);
    });
  }

  async function runChunkedUpload(file, title, updateProgress) {
    const initRes = await fetch('/api/upload/chunk/init', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ filename: file.name, size: file.size, title: title || '' })
    });
    if (!initRes.ok) {
      const data = await initRes.json().catch(() => ({}));
      throw new Error(data.error || 'Could not start upload (' + initRes.status + ').');
    }
    const init = await initRes.json();
    chunkUploadId = init.upload_id;
    chunkUploadCancelled = false;

    let offset = Number(init.offset || 0);
    let retries = 0;
    const total = file.size;
    const chunkSize = Number(init.chunk_size || LARGE_UPLOAD_CHUNK_SIZE);

    while (offset < total) {
      if (chunkUploadCancelled) throw new Error('Upload aborted.');
      const end = Math.min(total, offset + chunkSize);
      const blob = file.slice(offset, end);
      try {
        const res = await xhrUploadChunk(
          '/api/upload/chunk/' + encodeURIComponent(chunkUploadId),
          blob,
          offset,
          loaded => updateProgress(offset + loaded, total)
        );
        offset = Number(res.offset);
        retries = 0;
        updateProgress(offset, total);
      } catch (err) {
        if (err.status === 409 && Number.isFinite(Number(err.currentOffset))) {
          offset = Number(err.currentOffset);
          continue;
        }
        if (++retries <= 3) {
          await new Promise(resolve => setTimeout(resolve, 1000 * retries));
          continue;
        }
        throw err;
      }
    }

    const completeRes = await fetch(
      '/api/upload/chunk/' + encodeURIComponent(chunkUploadId) + '/complete',
      { method: 'POST' }
    );
    const result = await completeRes.json().catch(() => ({}));
    if (!completeRes.ok) throw new Error(result.error || 'Upload finalization failed (' + completeRes.status + ').');
    chunkUploadId = null;
    return result;
  }

  const originalStartUpload = startUpload;
  startUpload = async function() {
    if (!selectedUploadFile) return;
    const sb = document.getElementById('uploadSubmitBtn');
    const cb = document.getElementById('uploadCancelBtn');
    const pb = document.getElementById('uploadProgressBar');
    const pt = document.getElementById('uploadPercentText');
    const ps = document.getElementById('uploadStatusText');
    const pby = document.getElementById('uploadBytesText');
    const peta = document.getElementById('uploadEtaText');
    const psp = document.getElementById('uploadSpeedText');

    sb.disabled = true;
    sb.style.display = 'none';
    cb.textContent = 'Abort';
    document.getElementById('uploadDropZone').style.display = 'none';
    document.getElementById('uploadTitleWrap').style.display = 'none';
    document.getElementById('uploadProgressSection').style.display = 'flex';
    document.getElementById('uploadErrorBox').style.display = 'none';
    ps.textContent = 'Uploading media...';
    pb.style.width = '0%';
    pt.textContent = '0%';

    let lastTime = Date.now();
    let lastBytes = 0;
    let speed = 0;
    let progressTimer = null;
    const updateProgress = (bytes, total) => {
      const pct = Math.min(100, Math.round(bytes / total * 100));
      pb.style.width = pct + '%';
      pt.textContent = pct + '%';
      pby.textContent = fmtSize(bytes) + ' / ' + fmtSize(total);
      const now = Date.now();
      const dt = (now - lastTime) / 1000;
      if (dt >= 0.25) {
        const instant = (bytes - lastBytes) / dt;
        speed = speed > 0 ? (speed * 0.7 + instant * 0.3) : instant;
        psp.textContent = fmtSize(speed) + '/s';
        lastBytes = bytes;
        lastTime = now;
        const rem = total - bytes;
        if (peta) peta.textContent = speed > 0 ? 'ETA: ' + formatEta(Math.round(rem / speed)) : 'ETA: Calculating...';
      }
    };

    function formatEta(sec) {
      if (sec >= 3600) return Math.floor(sec / 3600) + 'h ' + Math.floor((sec % 3600) / 60) + 'm';
      if (sec >= 60) return Math.floor(sec / 60) + 'm ' + (sec % 60) + 's';
      return sec + 's';
    }

    cb.onclick = function() {
      if (uploadXHR && uploadXHR.readyState > 0 && uploadXHR.readyState < 4) uploadXHR.abort();
      abortChunkUploadSession();
      document.getElementById('uploadErrorMessage').textContent = 'Upload aborted.';
      document.getElementById('uploadErrorBox').style.display = 'flex';
      sb.style.display = 'inline-flex';
      sb.disabled = false;
      cb.textContent = 'Close';
    };

    try {
      const titleInput = document.getElementById('uploadTitleInput');
      const title = titleInput ? titleInput.value.trim() : '';
      const result = await runChunkedUpload(selectedUploadFile, title, updateProgress);
      pb.style.width = '100%';
      pt.textContent = '100%';
      pby.textContent = fmtSize(selectedUploadFile.size) + ' / ' + fmtSize(selectedUploadFile.size);
      psp.textContent = 'Done';
      if (peta) peta.textContent = 'Uploaded';
      ps.textContent = 'Processing media...';
      const tasksBox = document.getElementById('uploadTasksBox');
      if (tasksBox) tasksBox.style.display = 'flex';
      startProcessingCycle();

      document.getElementById('uploadProgressSection').style.display = 'none';
      document.getElementById('uploadTasksBox').style.display = 'none';
      document.getElementById('uploadFileCard').style.display = 'none';
      const sbox = document.getElementById('uploadSuccessBox');
      const smt = document.getElementById('successMovieTitle');
      if (smt) smt.textContent = (result.title || 'Media') + ' added successfully!';
      sbox.style.display = 'flex';
      stopProcessingCycle();
      setTimeout(() => location.reload(), 1500);
    } catch (err) {
      stopProcessingCycle();
      document.getElementById('uploadTasksBox').style.display = 'none';
      showUploadError(err.message || 'Upload failed.');
      sb.style.display = 'inline-flex';
      sb.disabled = false;
      cb.style.display = 'inline-flex';
      cb.textContent = 'Close';
    } finally {
      clearTimeout(progressTimer);
      uploadXHR = null;
    }
  };
}
