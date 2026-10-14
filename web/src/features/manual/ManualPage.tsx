import { NavLink } from 'react-router';
import { Icon } from '../../components/icons';

const SHORTCUTS = [
  { key: 'Space / K', desc: 'Toggle playback (Play / Pause)', category: 'Playback' },
  { key: 'J / L', desc: 'Seek backward / forward 10 seconds', category: 'Playback' },
  { key: '← / →', desc: 'Seek 5 seconds or step single frame when paused', category: 'Playback' },
  { key: '↑ / ↓', desc: 'Adjust audio volume by 5%', category: 'Audio' },
  { key: 'M', desc: 'Mute / Unmute audio', category: 'Audio' },
  { key: 'F', desc: 'Toggle cinema fullscreen', category: 'View' },
  { key: 'C', desc: 'Toggle subtitles on / off', category: 'Subtitles' },
  { key: '0 – 9', desc: 'Seek directly to percentage of timeline (0% – 90%)', category: 'Playback' },
  { key: 'N', desc: 'Toggle Technical Telemetry HUD (Stats for Nerds)', category: 'View' },
  { key: 'Esc', desc: 'Exit fullscreen, dismiss menus or return to details', category: 'Navigation' },
];

const GESTURES = [
  {
    title: 'Double Tap (Left / Right)',
    action: 'Rapid 10-Second Seek',
    desc: 'Double tapping the left side rewinds 10 seconds; the right side skips forward 10 seconds with animated ripple feedback.',
    icon: 'rotate' as const,
  },
  {
    title: 'Vertical Swipe (Left Half)',
    action: 'Screen Brightness',
    desc: 'Swiping vertically on the left half of the video canvas adjusts brightness smoothly without leaving the app.',
    icon: 'sparkle' as const,
  },
  {
    title: 'Vertical Swipe (Right Half)',
    action: 'System Volume',
    desc: 'Swiping vertically on the right half smoothly raises or lowers media volume with an instant HUD indicator.',
    icon: 'speakers' as const,
  },
  {
    title: 'Tap Screen Canvas',
    action: 'Show / Hide Controls',
    desc: 'A single tap reveals controls. While playing, controls auto-fade after 3 seconds of inactivity.',
    icon: 'play' as const,
  },
];

export function ManualPage() {
  return (
    <div className="mx-auto max-w-4xl space-y-8 animate-fade-in pb-12">
      {/* Hero Header */}
      <section className="glass-card rounded-3xl p-6 sm:p-10 shadow-xl text-center space-y-3">
        <span className="inline-flex items-center gap-1.5 rounded-full bg-brand-500/15 border border-brand-500/30 px-3 py-1 text-xs font-bold uppercase tracking-wider text-brand-300">
          <Icon name="book" size={14} />
          Documentation &amp; User Manual
        </span>
        <h1 className="text-2xl sm:text-4xl font-extrabold tracking-tight text-white">
          Controls &amp; Streaming Guide
        </h1>
        <p className="mx-auto max-w-xl text-sm sm:text-base text-white/60 leading-relaxed">
          Everything you need to master video playback, desktop keyboard shortcuts, mobile touch gestures, and dual-GPU streaming.
        </p>

        <div className="pt-2 flex flex-wrap items-center justify-center gap-2">
          <NavLink
            to="/"
            className="card-ring rounded-full bg-white/10 px-4 py-2 text-xs font-semibold text-white hover:bg-white/15 transition"
          >
            ← Back to Library
          </NavLink>
          <a
            href="/download"
            className="card-ring rounded-full brand-gradient px-4 py-2 text-xs font-semibold text-white hover:scale-105 active:scale-95 transition"
          >
            Download Android / TV App
          </a>
        </div>
      </section>

      {/* Keyboard Shortcuts Section */}
      <section className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6">
        <div className="flex items-center gap-2.5">
          <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-brand-500/15 text-brand-400 border border-brand-500/30">
            <Icon name="bolt" size={18} />
          </div>
          <div>
            <h2 className="text-xl font-bold text-white">Keyboard Shortcuts (Desktop)</h2>
            <p className="text-xs text-white/50">High-speed physical controls inside the player</p>
          </div>
        </div>

        <div className="overflow-hidden rounded-2xl border border-white/10 bg-obsidian-900/60 shadow-inner">
          <table className="w-full text-left text-xs sm:text-sm">
            <thead className="border-b border-white/10 bg-white/[0.03] text-white/50 text-xs uppercase tracking-wider">
              <tr>
                <th className="px-4 py-3 font-semibold">Key</th>
                <th className="px-4 py-3 font-semibold">Action</th>
                <th className="hidden sm:table-cell px-4 py-3 font-semibold text-right">Category</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-white/5 text-white/80">
              {SHORTCUTS.map((s) => (
                <tr key={s.key} className="hover:bg-white/[0.02] transition-colors">
                  <td className="px-4 py-3 font-mono font-bold text-brand-300">
                    <kbd className="rounded-lg border border-white/20 bg-white/10 px-2 py-1 text-xs shadow-sm">
                      {s.key}
                    </kbd>
                  </td>
                  <td className="px-4 py-3">{s.desc}</td>
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

      {/* Mobile Touch Gestures */}
      <section className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6">
        <div className="flex items-center gap-2.5">
          <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-emerald-500/15 text-emerald-400 border border-emerald-500/30">
            <Icon name="devices" size={18} />
          </div>
          <div>
            <h2 className="text-xl font-bold text-white">Touch Gestures (Mobile &amp; Tablets)</h2>
            <p className="text-xs text-white/50">Intuitive edge and surface touch actions</p>
          </div>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          {GESTURES.map((g) => (
            <div
              key={g.title}
              className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4.5 space-y-2 transition hover:border-white/20"
            >
              <div className="flex items-center justify-between">
                <span className="text-xs font-semibold text-emerald-400">{g.action}</span>
                <Icon name={g.icon} className="text-white/40" />
              </div>
              <h3 className="text-sm font-bold text-white">{g.title}</h3>
              <p className="text-xs text-white/60 leading-relaxed">{g.desc}</p>
            </div>
          ))}
        </div>
      </section>

      {/* Architecture & Multi-GPU Transcoding */}
      <section className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6">
        <div className="flex items-center gap-2.5">
          <div className="flex h-9 w-9 items-center justify-center rounded-2xl bg-sky-500/15 text-sky-400 border border-sky-500/30">
            <Icon name="gauge" size={18} />
          </div>
          <div>
            <h2 className="text-xl font-bold text-white">Dual-GPU Streaming &amp; Storage Engine</h2>
            <p className="text-xs text-white/50">Hardware acceleration architecture</p>
          </div>
        </div>

        <div className="space-y-4 text-xs sm:text-sm text-white/70 leading-relaxed">
          <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4 space-y-1.5">
            <h3 className="font-semibold text-white flex items-center gap-2">
              <span className="text-brand-400">⚡</span> Dynamic Multi-GPU Transcoding
            </h3>
            <p>
              When playing non-native video containers (such as high-bitrate MKV, HEVC 10-bit, or VC-1), the server automatically splits the timeline into keyframe-aligned segments and transcodes them concurrently across the discrete <strong>AMD Radeon RX 560X (dx11:1)</strong> and the integrated <strong>AMD Radeon Vega 8 (dx11:0)</strong> GPU engines.
            </p>
          </div>

          <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4 space-y-1.5">
            <h3 className="font-semibold text-white flex items-center gap-2">
              <span className="text-sky-400">💾</span> Dual-Drive Tiered Storage
            </h3>
            <p>
              Primary fast SSD <code>E:\</code> hosts application state, the SQLite database (<code>media.db</code>), in-progress transcode scratch, and HLS caches for stutter-free delivery. Mass secondary storage <code>D:\Flicks</code> holds raw multi-gigabyte files and cold archival pools.
            </p>
          </div>

          <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4 space-y-1.5">
            <h3 className="font-semibold text-white flex items-center gap-2">
              <span className="text-purple-400">💬</span> Subtitles &amp; Audio Streams
            </h3>
            <p>
              In-player subtitle settings allow adjusting font size, background contrast, horizontal alignment, and vertical elevation. External WebVTT / SRT files are auto-discovered from media directories or can be uploaded directly on movie detail pages.
            </p>
          </div>
        </div>
      </section>
    </div>
  );
}

export default ManualPage;
