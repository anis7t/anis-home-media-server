import { NavLink } from 'react-router';
import { Icon, type IconName } from '../../components/icons';

interface ShortcutItem {
  key: string;
  desc: string;
  category: string;
}

const SHORTCUTS: ShortcutItem[] = [
  { key: 'Space / K', desc: 'Toggle media playback (Play / Pause)', category: 'Playback' },
  { key: 'J / L', desc: 'Seek backward / forward 10 seconds with animated ripples', category: 'Playback' },
  { key: '← / →', desc: 'Fine-grained seek 5 seconds (frame-by-frame when paused)', category: 'Playback' },
  { key: '0 – 9', desc: 'Jump directly to percentage of timeline (0% – 90%)', category: 'Playback' },
  { key: 'Home', desc: 'Replay video from the very beginning (0:00)', category: 'Playback' },
  { key: '↑ / ↓', desc: 'Adjust audio volume by 5% with live HUD indicator', category: 'Audio' },
  { key: 'M', desc: 'Mute / Unmute audio immediately', category: 'Audio' },
  { key: 'F', desc: 'Toggle cinema fullscreen mode', category: 'View' },
  { key: 'C', desc: 'Toggle active subtitles on or off', category: 'Subtitles' },
  { key: '< / >', desc: 'Adjust playback speed (0.75×, 1×, 1.25×, 1.5×, 2×)', category: 'Playback' },
  { key: 'A', desc: 'Cycle aspect ratios (Contain, 16:9, 4:3, Fill Crop, Original)', category: 'View' },
  { key: 'R', desc: 'Cycle hardware CSS screen rotation by 90°', category: 'View' },
  { key: 'P / I', desc: 'Detach video into floating Picture-in-Picture window', category: 'View' },
  { key: 'N', desc: 'Toggle Technical Telemetry HUD (Stats for Nerds)', category: 'Telemetry' },
  { key: '?', desc: 'Open on-screen keyboard shortcuts modal', category: 'Navigation' },
  { key: 'Esc', desc: 'Exit fullscreen, dismiss modals or return to details', category: 'Navigation' },
];

interface GestureItem {
  title: string;
  action: string;
  desc: string;
  icon: IconName;
  highlight: string;
}

const GESTURES: GestureItem[] = [
  {
    title: 'Double Tap (Left 35%)',
    action: 'Rewind 10 Seconds',
    desc: 'Double tapping the left portion of the screen rewinds 10s with an animated backward ripple.',
    icon: 'rotate',
    highlight: 'text-amber-400',
  },
  {
    title: 'Double Tap (Right 35%)',
    action: 'Skip 10 Seconds',
    desc: 'Double tapping the right portion of the screen skips forward 10s with an animated forward ripple.',
    icon: 'rotate',
    highlight: 'text-emerald-400',
  },
  {
    title: 'Vertical Swipe (Left Half)',
    action: 'Screen Brightness',
    desc: 'Swiping up or down on the left half adjusts viewport display brightness with an on-screen slider HUD.',
    icon: 'sparkle',
    highlight: 'text-sky-400',
  },
  {
    title: 'Vertical Swipe (Right Half)',
    action: 'Media Volume',
    desc: 'Swiping up or down on the right half raises or lowers audio volume with an instant level percentage.',
    icon: 'speakers',
    highlight: 'text-purple-400',
  },
  {
    title: 'Tap Screen Canvas',
    action: 'Toggle Controls Bar',
    desc: 'Single tapping reveals the player controls bar without toggling play/pause. Controls auto-hide after 3s.',
    icon: 'play',
    highlight: 'text-brand-400',
  },
  {
    title: 'Tap Elapsed Timestamp',
    action: 'Elapsed / Remaining Time',
    desc: 'Tapping the bottom timestamp toggles between elapsed playback time and negative countdown time.',
    icon: 'clock',
    highlight: 'text-rose-400',
  },
];

const JUMP_LINKS = [
  { id: 'shortcuts', label: 'Shortcuts', icon: 'bolt' as const },
  { id: 'gestures', label: 'Touch Gestures', icon: 'sparkle' as const },
  { id: 'tv-remote', label: '10-Foot TV Remote', icon: 'tv' as const },
  { id: 'pairing', label: 'Device Pairing', icon: 'devices' as const },
  { id: 'subtitles', label: 'Subtitles', icon: 'subtitles' as const },
  { id: 'casting', label: 'LAN Cast & DLNA', icon: 'cast' as const },
  { id: 'architecture', label: 'Dual-GPU Engine', icon: 'gauge' as const },
  { id: 'security', label: 'Admin Security', icon: 'shield' as const },
];

export function ManualPage() {
  const scrollTo = (id: string) => {
    const el = document.getElementById(id);
    if (el) {
      el.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  };

  return (
    <div className="mx-auto max-w-4xl space-y-10 animate-fade-in pb-16">
      {/* Hero Header */}
      <section className="relative overflow-hidden glass-card rounded-3xl p-6 sm:p-10 shadow-2xl text-center space-y-4">
        {/* Subtle Ambient Radial Lighting */}
        <div className="pointer-events-none absolute -top-24 left-1/2 -translate-x-1/2 w-96 h-96 rounded-full bg-gradient-to-b from-brand-500/15 via-sky-500/5 to-transparent blur-3xl" />

        <div className="relative inline-flex items-center gap-1.5 rounded-full bg-brand-500/15 border border-brand-500/30 px-3.5 py-1 text-xs font-bold uppercase tracking-wider text-brand-300">
          <Icon name="book" size={14} />
          Documentation &amp; User Manual
        </div>

        <h1 className="relative text-2xl sm:text-4xl font-extrabold tracking-tight text-white">
          Controls, Streaming &amp; Architecture Guide
        </h1>

        <p className="relative mx-auto max-w-2xl text-sm sm:text-base text-white/70 leading-relaxed">
          Comprehensive guide to desktop shortcuts, mobile gestures, 10-foot Fire TV remote navigation, passwordless device pairing, dual-GPU acceleration, and admin storage controls.
        </p>

        <div className="relative pt-2 flex flex-wrap items-center justify-center gap-3">
          <NavLink
            to="/"
            className="card-ring rounded-full border border-white/15 bg-white/5 px-4 py-2 text-xs font-semibold text-white/80 hover:bg-white/10 hover:text-white transition flex items-center gap-1.5"
          >
            ← Back to Library
          </NavLink>
          <a
            href="/download"
            className="card-ring rounded-full brand-gradient px-4.5 py-2 text-xs font-bold text-white shadow-lg shadow-brand-500/25 hover:shadow-brand-500/40 hover:scale-[1.02] active:scale-[0.98] transition flex items-center gap-1.5"
          >
            <Icon name="download" size={13} />
            <span>Download Android / TV App</span>
          </a>
        </div>
      </section>

      {/* Quick-Jump Section Navigation Strip */}
      <nav
        aria-label="Manual section navigation"
        className="flex items-center gap-2 overflow-x-auto py-1 scrollbar-none overscroll-contain"
      >
        {JUMP_LINKS.map((link) => (
          <button
            key={link.id}
            type="button"
            onClick={() => scrollTo(link.id)}
            className="card-ring shrink-0 inline-flex items-center gap-1.5 rounded-full border border-white/10 bg-obsidian-900/80 px-3.5 py-1.5 text-xs font-semibold text-white/70 hover:border-brand-500/40 hover:bg-brand-500/10 hover:text-white transition cursor-pointer"
          >
            <Icon name={link.icon} size={13} />
            <span>{link.label}</span>
          </button>
        ))}
      </nav>

      {/* 1. Desktop Keyboard Shortcuts */}
      <section id="shortcuts" className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6 scroll-mt-20">
        <div className="flex items-center gap-2.5">
          <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-brand-500/15 text-brand-400 border border-brand-500/30">
            <Icon name="bolt" size={18} />
          </div>
          <div>
            <h2 className="text-xl font-bold text-white">Desktop Keyboard Shortcuts</h2>
            <p className="text-xs text-white/50">High-speed physical controls inside the video player</p>
          </div>
        </div>

        <div className="overflow-hidden rounded-2xl border border-white/10 bg-obsidian-900/60 shadow-inner">
          <table className="w-full text-left text-xs sm:text-sm">
            <thead className="border-b border-white/10 bg-white/[0.03] text-white/50 text-xs uppercase tracking-wider">
              <tr>
                <th className="px-4 py-3 font-semibold">Key</th>
                <th className="px-4 py-3 font-semibold">Action &amp; Behavior</th>
                <th className="hidden sm:table-cell px-4 py-3 font-semibold text-right">Category</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-white/5 text-white/80">
              {SHORTCUTS.map((s) => (
                <tr key={s.key} className="hover:bg-white/[0.02] transition-colors">
                  <td className="px-4 py-3 font-mono font-bold text-brand-300 whitespace-nowrap">
                    <kbd className="rounded-lg border border-white/20 bg-white/10 px-2.5 py-1 text-xs shadow-sm">
                      {s.key}
                    </kbd>
                  </td>
                  <td className="px-4 py-3 text-white/90">{s.desc}</td>
                  <td className="hidden sm:table-cell px-4 py-3 text-right text-xs text-white/40">
                    <span className="rounded-full bg-white/5 px-2.5 py-0.5 border border-white/10">
                      {s.category}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      {/* 2. Mobile Touch Gestures */}
      <section id="gestures" className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6 scroll-mt-20">
        <div className="flex items-center gap-2.5">
          <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-emerald-500/15 text-emerald-400 border border-emerald-500/30">
            <Icon name="sparkle" size={18} />
          </div>
          <div>
            <h2 className="text-xl font-bold text-white">Touch Gestures (Phones &amp; Tablets)</h2>
            <p className="text-xs text-white/50">Fluid multi-touch controls on mobile viewports</p>
          </div>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3.5">
          {GESTURES.map((g) => (
            <div
              key={g.title}
              className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4.5 space-y-2 transition hover:border-white/20"
            >
              <div className="flex items-center justify-between">
                <span className={`text-xs font-bold ${g.highlight}`}>{g.action}</span>
                <span className="text-white/40">
                  <Icon name={g.icon} size={16} />
                </span>
              </div>
              <h3 className="text-sm font-bold text-white">{g.title}</h3>
              <p className="text-xs text-white/60 leading-relaxed">{g.desc}</p>
            </div>
          ))}
        </div>
      </section>

      {/* 3. 10-Foot TV Remote Navigation (Fire TV & Android TV) */}
      <section id="tv-remote" className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6 scroll-mt-20">
        <div className="flex items-center gap-2.5">
          <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-sky-500/15 text-sky-400 border border-sky-500/30">
            <Icon name="tv" size={18} />
          </div>
          <div>
            <h2 className="text-xl font-bold text-white">10-Foot TV Remote Navigation</h2>
            <p className="text-xs text-white/50">Fire TV Stick 4K and Android TV directional remote controls</p>
          </div>
        </div>

        <div className="space-y-4 text-xs sm:text-sm text-white/70 leading-relaxed">
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4.5 space-y-2">
              <span className="inline-flex items-center gap-1.5 text-xs font-bold text-sky-400">
                Zone 1: Timeline Scrubber
              </span>
              <h3 className="text-sm font-bold text-white">Left / Right D-Pad Scrubbing</h3>
              <p className="text-xs text-white/60 leading-relaxed">
                When player controls appear, remote focus defaults to the timeline scrubber. Pressing <strong>Left</strong> or <strong>Right</strong> scrubs backward or forward with live thumbnail previews. Press <strong>Center / Select</strong> to commit the seek.
              </p>
            </div>

            <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4.5 space-y-2">
              <span className="inline-flex items-center gap-1.5 text-xs font-bold text-sky-400">
                Zone 2: Transport Rail
              </span>
              <h3 className="text-sm font-bold text-white">Down D-Pad Navigation</h3>
              <p className="text-xs text-white/60 leading-relaxed">
                Pressing <strong>Down</strong> steps focus into the lower control buttons: Restart (↺), Skip ±10s, Play/Pause, Volume, Playback Speed (1×), and Subtitles. Press <strong>Up</strong> to return to the timeline scrubber.
              </p>
            </div>
          </div>

          {/* Back Key Protocol Card */}
          <div className="rounded-2xl border border-sky-500/25 bg-sky-500/[0.04] p-5 space-y-2.5">
            <div className="flex items-center gap-2">
              <span className="flex h-6 w-6 items-center justify-center rounded-lg bg-sky-500/20 text-sky-400 text-xs font-bold">
                ↩
              </span>
              <h4 className="text-sm font-bold text-white">The TV Remote Back Button Protocol</h4>
            </div>
            <p className="text-xs text-white/70 leading-relaxed">
              To prevent accidental route exits while streaming in a cinema environment:
            </p>
            <ul className="space-y-1.5 text-xs text-white/70 list-disc list-inside">
              <li>
                <strong>1st Back Press (Controls Hidden):</strong> Reveals the player controls and focuses the timeline scrubber without stopping video playback.
              </li>
              <li>
                <strong>2nd Back Press (Controls Visible):</strong> Saves playback progress, stops playback, and exits cleanly to the movie details screen.
              </li>
            </ul>
          </div>
        </div>
      </section>

      {/* 4. Zero-Password Device Pairing & Tokens */}
      <section id="pairing" className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6 scroll-mt-20">
        <div className="flex items-center gap-2.5">
          <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-amber-500/15 text-amber-400 border border-amber-500/30">
            <Icon name="devices" size={18} />
          </div>
          <div>
            <h2 className="text-xl font-bold text-white">Zero-Password Device Pairing</h2>
            <p className="text-xs text-white/50">Pair Smart TVs and secondary devices without typing passwords</p>
          </div>
        </div>

        <div className="space-y-4">
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-3.5 text-xs">
            <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4 space-y-2">
              <span className="flex h-7 w-7 items-center justify-center rounded-xl bg-amber-500/15 text-amber-400 font-bold">
                1
              </span>
              <h3 className="font-bold text-sm text-white">Generate Code</h3>
              <p className="text-white/60 leading-relaxed">
                Open <strong>Account &amp; Devices</strong> on your phone or PC. Enter a device name and click <strong>Generate Pairing Token</strong>.
              </p>
            </div>

            <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4 space-y-2">
              <span className="flex h-7 w-7 items-center justify-center rounded-xl bg-amber-500/15 text-amber-400 font-bold">
                2
              </span>
              <h3 className="font-bold text-sm text-white">Enter on TV</h3>
              <p className="text-white/60 leading-relaxed">
                Open the Fire TV or Android TV app. Enter the 6-character code into the pairing dialog. Codes remain valid for 15 minutes.
              </p>
            </div>

            <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4 space-y-2">
              <span className="flex h-7 w-7 items-center justify-center rounded-xl bg-amber-500/15 text-amber-400 font-bold">
                3
              </span>
              <h3 className="font-bold text-sm text-white">1-Year Token</h3>
              <p className="text-white/60 leading-relaxed">
                The TV receives a cryptographically secure 1-year device token, instantly adopting your account watch history and resume points.
              </p>
            </div>
          </div>

          <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-4 flex flex-col sm:flex-row items-center justify-between gap-3 text-xs">
            <span className="text-white/70">
              Both server administrators and regular signed-in users can pair devices in their own user scope.
            </span>
            <NavLink
              to="/account"
              className="card-ring shrink-0 rounded-full border border-amber-500/30 bg-amber-500/10 px-4 py-2 text-xs font-semibold text-amber-300 hover:bg-amber-500/20 transition"
            >
              Go to Account &amp; Pairing →
            </NavLink>
          </div>
        </div>
      </section>

      {/* 5. Subtitles & Dual-Axis Positioning */}
      <section id="subtitles" className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6 scroll-mt-20">
        <div className="flex items-center gap-2.5">
          <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-purple-500/15 text-purple-400 border border-purple-500/30">
            <Icon name="subtitles" size={18} />
          </div>
          <div>
            <h2 className="text-xl font-bold text-white">Subtitles &amp; Dual-Axis Customization</h2>
            <p className="text-xs text-white/50">Typography, cue elevation, and intelligent language auto-detection</p>
          </div>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 text-xs sm:text-sm text-white/70">
          <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4.5 space-y-2">
            <h3 className="text-sm font-bold text-white flex items-center gap-2">
              <span className="text-purple-400">📐</span> Dual-Axis Alignment
            </h3>
            <p className="text-xs text-white/60 leading-relaxed">
              Configure both <strong>Horizontal Alignment</strong> (Left, Center, Right) and <strong>Vertical Placement</strong> (Top, Middle, Raised, Bottom, Lowered). When player controls appear, cues automatically elevate upward so the seekbar never obscures dialogue.
            </p>
          </div>

          <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4.5 space-y-2">
            <h3 className="text-sm font-bold text-white flex items-center gap-2">
              <span className="text-purple-400">🌐</span> Language Auto-Detection
            </h3>
            <p className="text-xs text-white/60 leading-relaxed">
              Upload any <code>.srt</code> or <code>.vtt</code> file in-player or on movie details. The server analyzes Unicode script blocks and NLP stop-word frequency to classify English, Hindi, Spanish, French, German, and Arabic automatically.
            </p>
          </div>
        </div>
      </section>

      {/* 6. Second-Screen Playback (LAN Cast & DLNA) */}
      <section id="casting" className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6 scroll-mt-20">
        <div className="flex items-center gap-2.5">
          <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-rose-500/15 text-rose-400 border border-rose-500/30">
            <Icon name="cast" size={18} />
          </div>
          <div>
            <h2 className="text-xl font-bold text-white">Second-Screen Playback (LAN Cast &amp; DLNA)</h2>
            <p className="text-xs text-white/50">Stream directly to smart TVs, Chromecast, and Google Nest Hub</p>
          </div>
        </div>

        <div className="space-y-4 text-xs sm:text-sm text-white/70 leading-relaxed">
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4.5 space-y-2">
              <h3 className="text-sm font-bold text-white flex items-center gap-2">
                <span className="text-rose-400">📺</span> Smart TVs (DLNA / UPnP)
              </h3>
              <p className="text-xs text-white/60 leading-relaxed">
                Discovers Samsung Tizen and LG webOS smart TVs on your home Wi-Fi. Media is streamed directly using OS-level RFC 7233 byte-range delivery with zero browser transcoding overhead.
              </p>
            </div>

            <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4.5 space-y-2">
              <h3 className="text-sm font-bold text-white flex items-center gap-2">
                <span className="text-rose-400">📡</span> Google Cast Ecosystem
              </h3>
              <p className="text-xs text-white/60 leading-relaxed">
                Connects to Chromecast with Google TV and Nest Hub devices. MKV and HEVC containers are adapted on the fly to Cast-compliant HLS streams with live WebVTT subtitle track selection.
              </p>
            </div>
          </div>

          <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-4 text-xs text-white/60 flex items-center gap-3">
            <span className="text-lg">🔊</span>
            <span>
              Adjusting volume or muting in the web player synchronizes with the TV&apos;s physical master volume in real time. Disconnecting gracefully closes the receiver app and returns the TV to its home screen.
            </span>
          </div>
        </div>
      </section>

      {/* 7. Architecture & Multi-GPU Transcoding */}
      <section id="architecture" className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6 scroll-mt-20">
        <div className="flex items-center gap-2.5">
          <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-brand-500/15 text-brand-400 border border-brand-500/30">
            <Icon name="gauge" size={18} />
          </div>
          <div>
            <h2 className="text-xl font-bold text-white">Dual-GPU Streaming &amp; Storage Topology</h2>
            <p className="text-xs text-white/50">Hardware acceleration architecture and SSD/HDD tiering</p>
          </div>
        </div>

        <div className="space-y-4 text-xs sm:text-sm text-white/70 leading-relaxed">
          <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4.5 space-y-2">
            <h3 className="font-bold text-sm text-white flex items-center gap-2">
              <span className="text-brand-400">⚡</span> Dynamic Multi-GPU Transcoding
            </h3>
            <p className="text-xs text-white/60 leading-relaxed">
              For MKV and HEVC video streams, the server partitions timelines into keyframe-aligned chunks and encodes them concurrently across the discrete <strong>AMD Radeon RX 560X (dx11:1)</strong> and the integrated <strong>AMD Radeon Vega 8 (dx11:0)</strong> GPUs with monotonic presentation timestamps.
            </p>
          </div>

          <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4.5 space-y-2">
            <h3 className="font-bold text-sm text-white flex items-center gap-2">
              <span className="text-sky-400">💾</span> Dual-Drive Storage Tiering
            </h3>
            <p className="text-xs text-white/60 leading-relaxed">
              Fast SSD <code>E:\MediaServer</code> hosts application code, the SQLite database (<code>media.db</code>), in-progress scratch, and completed HLS caches for instant responses. Mass storage drive <code>D:\Flicks</code> holds raw multi-gigabyte video files, upload staging, and cold archives. Drive <code>C:</code> is never used.
            </p>
          </div>

          <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4.5 space-y-2">
            <h3 className="font-bold text-sm text-white flex items-center gap-2">
              <span className="text-emerald-400">⚡</span> Instant Cache Detection (&lt; 100ms)
            </h3>
            <p className="text-xs text-white/60 leading-relaxed">
              The library management inventory uses synchronous directory existence probing to detect existing HLS transcode caches instantly upon page load, eliminating frozen status bars or delay.
            </p>
          </div>
        </div>
      </section>

      {/* 8. Admin Security & Retention Policies */}
      <section id="security" className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6 scroll-mt-20">
        <div className="flex items-center gap-2.5">
          <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-amber-500/15 text-amber-400 border border-amber-500/30">
            <Icon name="shield" size={18} />
          </div>
          <div>
            <h2 className="text-xl font-bold text-white">Admin Security &amp; Retention Policies</h2>
            <p className="text-xs text-white/50">Storage pool policies, fail-closed PIN channel, and fleet privacy</p>
          </div>
        </div>

        <div className="space-y-4 text-xs sm:text-sm text-white/70 leading-relaxed">
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-3.5">
            <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4 space-y-1.5">
              <h3 className="font-bold text-xs uppercase tracking-wider text-amber-300">keep (Default)</h3>
              <p className="text-xs text-white/60 leading-relaxed">
                Retains raw files in <code>D:\Flicks</code> and HLS stream caches on SSD indefinitely for instant playback.
              </p>
            </div>
            <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4 space-y-1.5">
              <h3 className="font-bold text-xs uppercase tracking-wider text-sky-300">archive</h3>
              <p className="text-xs text-white/60 leading-relaxed">
                Moves raw files to <code>D:\Flicks\.archive</code> while keeping fast SSD HLS stream caches active.
              </p>
            </div>
            <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4 space-y-1.5">
              <h3 className="font-bold text-xs uppercase tracking-wider text-rose-300">purge_cache</h3>
              <p className="text-xs text-white/60 leading-relaxed">
                Clears temporary HLS transcode caches once watched to conserve fast SSD drive headroom.
              </p>
            </div>
          </div>

          <div className="rounded-2xl border border-amber-500/25 bg-amber-500/[0.04] p-4.5 space-y-2">
            <h4 className="font-bold text-sm text-white flex items-center gap-2">
              <Icon name="shield" size={15} className="text-amber-400" />
              <span>Admin PIN Invariant &amp; Fleet Privacy Scoping</span>
            </h4>
            <p className="text-xs text-white/70 leading-relaxed">
              Destructive routes (permanent deletion, cache purging, policy updates, library rescan, and file uploads) require an authorized Google administrator session or the Admin PIN. The PIN fails closed with no default and is never accepted via query strings. Visiting <code>/devices</code> scopes telemetry to your current device only, keeping household IP addresses private unless unlocked with the Admin PIN.
            </p>
          </div>
        </div>
      </section>
    </div>
  );
}

export default ManualPage;
