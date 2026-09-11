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

    // Reset state
    progressBar.classList.remove('finish', 'fade-out');
    progressBar.classList.add('active');
    progressFill.style.transition = 'none';
    progressFill.style.width = '0%';
    progressBar.style.opacity = '1';

    // Force layout reflow
    void progressBar.offsetWidth;

    // Phase 1: Quick burst to 32%
    progressFill.style.transition = 'width 140ms cubic-bezier(0.1, 0.9, 0.2, 1)';
    progressFill.style.width = '32%';

    // Phase 2: Steady creep to 82% while waiting for network response
    progressTimer = setTimeout(() => {
      progressFill.style.transition = 'width 1.8s cubic-bezier(0.08, 0.8, 0.15, 1)';
      progressFill.style.width = '82%';
    }, 150);

    // Subtle dimming on leaving page
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
    if (document.body) {
      document.body.classList.remove('page-navigating');
    }
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

    // Don't trigger for same-page hash jumps
    if (a.pathname === window.location.pathname && a.search === window.location.search) {
      if (a.hash) return false;
    }

    return true;
  }

  // Intercept click on internal links
  document.addEventListener('click', function(e) {
    if (e.defaultPrevented || e.button !== 0) return;
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;

    const link = e.target.closest('a');
    if (!link || !isInternalLink(link)) return;

    startProgress();
  }, { capture: true, passive: true });

  // Finish progress when DOM is loaded or page restored
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => {
      createProgressBar();
      finishProgress();
    });
  } else {
    createProgressBar();
    finishProgress();
  }

  // Handle bfcache (back/forward cache) restoration
  window.addEventListener('pageshow', function(e) {
    if (e.persisted) {
      resetProgress();
    } else {
      finishProgress();
    }
  });

  // Reset if navigation is cancelled or interrupted
  window.addEventListener('pagehide', function() {
    // Keep clean for navigation
  });

  // Export to window for programmatic use if desired
  window.NavTransitions = {
    start: startProgress,
    finish: finishProgress,
    reset: resetProgress
  };
})();

