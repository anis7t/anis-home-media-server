import { useState, useCallback } from 'react';
import { Icon } from '../../components/icons';

const PRODUCTION_VERSION = '1.2.20';
const PRODUCTION_SIZE = '97.5 MB';
const PRODUCTION_SHA256 =
  '7bc4e2716e0f753bf4ca7a142b4a20d69cb7057c3717d10bb42ca052eda168f2';

export default function DownloadPage() {
  const [copied, setCopied] = useState(false);

  const handleCopySha = useCallback(() => {
    if (typeof navigator !== 'undefined' && navigator.clipboard) {
      navigator.clipboard.writeText(PRODUCTION_SHA256).then(() => {
        setCopied(true);
        setTimeout(() => setCopied(false), 2000);
      });
    }
  }, []);

  return (
    <main className="min-h-screen px-4 py-8 sm:px-6 lg:px-8 max-w-6xl mx-auto space-y-8 animate-fade-in text-white">
      {/* Hero Header */}
      <div className="text-center space-y-3 pt-4 sm:pt-6">
        <div className="inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-semibold bg-red-500/10 text-red-400 border border-red-500/20">
          <Icon name="download" size={13} className="text-red-400" />
          <span>OFFICIAL CLIENT APPS</span>
        </div>
        <h1 className="text-3xl sm:text-4xl lg:text-5xl font-extrabold tracking-tight bg-gradient-to-r from-white via-neutral-200 to-neutral-400 bg-clip-text text-transparent">
          Get the Media Server App
        </h1>
        <p className="max-w-2xl mx-auto text-sm sm:text-base text-neutral-400">
          Stream your high-bitrate library seamlessly across Android phones, tablets, Android TV,
          and Amazon Fire TV Stick 4K with native hardware acceleration.
        </p>
      </div>

      {/* Main Grid: Mobile & TV */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        {/* Card 1: Mobile & Tablet */}
        <section
          aria-labelledby="mobileAppTitle"
          className="glass-card rounded-2xl p-6 sm:p-8 flex flex-col justify-between border border-neutral-800/80 bg-neutral-900/60 backdrop-blur-md relative overflow-hidden group hover:border-red-500/30 transition-all duration-300"
        >
          <div className="space-y-5">
            <div className="flex items-center justify-between">
              <div className="w-12 h-12 rounded-xl bg-red-500/10 border border-red-500/20 flex items-center justify-center text-red-500 group-hover:scale-110 transition-transform">
                <Icon name="devices" size={24} />
              </div>
              <div className="flex items-center gap-2">
                <span className="glass-pill text-xs px-2.5 py-1 text-emerald-400 bg-emerald-500/10 border-emerald-500/20 font-mono">
                  v{PRODUCTION_VERSION}
                </span>
                <span className="glass-pill text-xs px-2.5 py-1 text-neutral-400 bg-neutral-800/60 border-neutral-700/40">
                  {PRODUCTION_SIZE}
                </span>
              </div>
            </div>

            <div>
              <h2 id="mobileAppTitle" className="text-xl sm:text-2xl font-bold text-white">
                Android Phones & Tablets
              </h2>
              <p className="text-sm text-neutral-400 mt-1">
                Touch gestures, portrait & landscape playback, background caching, and direct
                casting control from your pocket.
              </p>
            </div>

            <ul className="space-y-2 text-xs sm:text-sm text-neutral-300">
              <li className="flex items-center gap-2">
                <span className="text-emerald-400">✓</span> Vertical swipe brightness & volume gestures
              </li>
              <li className="flex items-center gap-2">
                <span className="text-emerald-400">✓</span> Symmetrical seekbar with dual elapsed/remaining HUD
              </li>
              <li className="flex items-center gap-2">
                <span className="text-emerald-400">✓</span> Automatic zero-copy Direct Play for native MP4 & MKV
              </li>
              <li className="flex items-center gap-2">
                <span className="text-emerald-400">✓</span> Compatible with Android 7.0+ (API 24 to 36)
              </li>
            </ul>
          </div>

          <div className="pt-6 mt-6 border-t border-neutral-800/80 space-y-3">
            <a
              href="/api/app/download?channel=production"
              download={`media-server-production-${PRODUCTION_VERSION}.apk`}
              className="w-full inline-flex items-center justify-center gap-2 py-3.5 px-5 rounded-xl font-semibold text-sm bg-gradient-to-r from-red-600 to-red-700 hover:from-red-500 hover:to-red-600 text-white shadow-lg shadow-red-900/30 hover:shadow-red-800/50 transition-all active:scale-[0.98]"
            >
              <Icon name="download" size={18} />
              <span>Download Production APK</span>
            </a>

            <div className="flex items-center justify-between text-xs text-neutral-500 px-1">
              <span>Universal Release (arm64, armv7, x86_64)</span>
              <a
                href="/api/app/download?channel=developer"
                className="hover:text-neutral-300 underline underline-offset-2 transition-colors"
              >
                Developer Channel
              </a>
            </div>
          </div>
        </section>

        {/* Card 2: 10-Foot TV & Fire TV */}
        <section
          aria-labelledby="tvAppTitle"
          className="glass-card rounded-2xl p-6 sm:p-8 flex flex-col justify-between border border-neutral-800/80 bg-neutral-900/60 backdrop-blur-md relative overflow-hidden group hover:border-red-500/30 transition-all duration-300"
        >
          <div className="space-y-5">
            <div className="flex items-center justify-between">
              <div className="w-12 h-12 rounded-xl bg-purple-500/10 border border-purple-500/20 flex items-center justify-center text-purple-400 group-hover:scale-110 transition-transform">
                <Icon name="tv" size={24} />
              </div>
              <span className="glass-pill text-xs px-2.5 py-1 text-purple-300 bg-purple-500/10 border-purple-500/20">
                10-Foot Cinema Mode
              </span>
            </div>

            <div>
              <h2 id="tvAppTitle" className="text-xl sm:text-2xl font-bold text-white">
                Amazon Fire TV & Android TV
              </h2>
              <p className="text-sm text-neutral-400 mt-1">
                Optimized for TV D-pad remotes with 2-zone navigation, MediaTek hardware decoding,
                and seamless LAN connectivity.
              </p>
            </div>

            <div className="space-y-3 bg-neutral-950/40 rounded-xl p-3.5 border border-neutral-800/60 text-xs text-neutral-300">
              <p className="font-semibold text-neutral-200">How to Sideload on Fire TV:</p>
              <ol className="list-decimal list-inside space-y-1.5 text-neutral-400">
                <li>Install the orange <strong>Downloader</strong> app from Amazon Appstore.</li>
                <li>
                  Enter this server's download URL:
                  <code className="block mt-1 p-1.5 bg-neutral-900 rounded text-neutral-300 font-mono text-[11px] select-all">
                    {typeof window !== 'undefined'
                      ? `${window.location.origin}/api/app/download`
                      : 'http://<server-ip>:8000/api/app/download'}
                  </code>
                </li>
                <li>Click <strong>Go</strong> to download and install. Launch and enjoy!</li>
              </ol>
            </div>
          </div>

          <div className="pt-6 mt-6 border-t border-neutral-800/80 space-y-3">
            <a
              href="/api/app/download?channel=production"
              download={`media-server-tv-${PRODUCTION_VERSION}.apk`}
              className="w-full inline-flex items-center justify-center gap-2 py-3.5 px-5 rounded-xl font-semibold text-sm bg-neutral-800 hover:bg-neutral-700 text-white border border-neutral-700 hover:border-neutral-600 transition-all active:scale-[0.98]"
            >
              <Icon name="download" size={18} />
              <span>Download for TV & Fire TV</span>
            </a>

            <div className="text-center text-xs text-neutral-500">
              Supports Fire TV Stick 4K, Chromecast with Google TV, and Shield TV
            </div>
          </div>
        </section>
      </div>

      {/* Security & Fingerprint Card */}
      <section
        aria-labelledby="securityTitle"
        className="glass-card rounded-2xl p-6 border border-neutral-800/60 bg-neutral-900/40 space-y-3 text-xs"
      >
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-2">
          <div className="flex items-center gap-2 font-semibold text-neutral-300">
            <Icon name="shield" size={16} className="text-emerald-400" />
            <h3 id="securityTitle" className="text-sm">Cryptographic Verification & Integrity</h3>
          </div>
          <button
            type="button"
            onClick={handleCopySha}
            className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg bg-neutral-800 hover:bg-neutral-700 text-neutral-300 border border-neutral-700 text-xs transition-colors"
          >
            <Icon name="check" size={12} className={copied ? 'text-emerald-400' : 'text-neutral-400'} />
            <span>{copied ? 'Copied SHA-256!' : 'Copy Fingerprint'}</span>
          </button>
        </div>

        <p className="text-neutral-400">
          Every APK is cryptographically signed and built from this repository. Verify the integrity
          of the downloaded binary with SHA-256:
        </p>
        <pre className="p-2.5 bg-neutral-950/80 rounded-lg text-neutral-300 font-mono text-[11px] overflow-x-auto border border-neutral-800/40 select-all">
          {PRODUCTION_SHA256}
        </pre>
      </section>
    </main>
  );
}
