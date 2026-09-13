/* Compatibility loader. Keep the original navigation/upload behavior, then load the player seek-bar enhancement. */
(function () {
  'use strict';
  const load = (src) => new Promise((resolve, reject) => {
    if (document.querySelector('script[data-loader="' + src + '"]')) return resolve();
    const s = document.createElement('script');
    s.src = src;
    s.dataset.loader = src;
    s.onload = resolve;
    s.onerror = reject;
    document.head.appendChild(s);
  });
  const css = document.createElement('link');
  css.rel = 'stylesheet';
  css.href = '/static/css/seekbar-youtube.css';
  document.head.appendChild(css);
  const previewCss = document.createElement('link');
  previewCss.rel = 'stylesheet';
  previewCss.href = '/static/css/seek-preview.css';
  document.head.appendChild(previewCss);
  load('/static/js/nav-original.js').catch(() => {});
  load('/static/js/seekbar-youtube.js').catch(() => {});
})();
