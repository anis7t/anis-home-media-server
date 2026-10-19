import { useCallback, useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import { NavLink } from 'react-router';
import { Icon } from '../../components/icons';
import { getStoredAdminPin } from '../../lib/api/account';

export interface WatchHistoryItem {
  filename: string;
  title: string;
  year: string | number;
  position: number;
  duration: number;
  position_str: string;
  duration_str: string;
  percent: number;
  completed: boolean;
  last_watched: string;
  last_watched_ago: string;
  poster_url: string | null;
}

interface DeviceItem {
  device_id: string;
  device_name: string;
  display_name: string;
  custom_name: string | null;
  device_icon: string;
  device_type: string;
  device_os: string;
  browser: string;
  client_ip: string;
  connection_type: string;
  isp: string;
  city: string;
  country: string;
  first_seen: string;
  last_seen: string;
  is_active: boolean;
  is_current: boolean;
  total_watched?: number;
  recent_watch?: WatchHistoryItem | { filename: string; percent: number } | null;
  watch_history?: WatchHistoryItem[];
}

interface DevicesResponse {
  current_device_id: string;
  devices: DeviceItem[];
  stats: {
    total_devices: number;
    active_now: number;
    offline: number;
  };
}

export function DevicesPage() {
  const [data, setData] = useState<DevicesResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<'all' | 'active' | 'offline'>('all');
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editName, setEditName] = useState('');
  const [busy, setBusy] = useState(false);
  const [selectedDeviceHistory, setSelectedDeviceHistory] = useState<DeviceItem | null>(null);

  // Fleet Telemetry Admin PIN Unlock State
  const [showPinModal, setShowPinModal] = useState(false);
  const [pinInputValue, setPinInputValue] = useState('');
  const [pinModalError, setPinModalError] = useState<string | null>(null);
  const [isFleetUnlocked, setIsFleetUnlocked] = useState(false);

  const getAdminHeaders = useCallback((): Record<string, string> => {
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    const pin = getStoredAdminPin();
    if (pin) headers['X-Admin-Pin'] = pin;
    return headers;
  }, []);

  const loadDevices = useCallback(async (signal?: AbortSignal) => {
    try {
      const pin = getStoredAdminPin();
      const headers: Record<string, string> = {};
      if (pin) headers['X-Admin-Pin'] = pin;
      const res = await fetch('/api/devices', { headers, signal });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const body = (await res.json()) as DevicesResponse;
      setData(body);
      setError(null);
    } catch (err) {
      if (err instanceof DOMException && err.name === 'AbortError') return;
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }, []);

  const handleVerifyFleetPin = async (candidatePin: string) => {
    setPinModalError(null);
    try {
      const res = await fetch('/api/admin/verify', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ pin: candidatePin }),
      });
      const resData = (await res.json()) as { success?: boolean; error?: string };
      if (res.ok && resData.success) {
        if (typeof sessionStorage !== 'undefined') {
          sessionStorage.setItem('ms_admin_pin', candidatePin);
          sessionStorage.setItem('ms_admin_unlocked', 'true');
        }
        setIsFleetUnlocked(true);
        setShowPinModal(false);
        setPinInputValue('');
        await loadDevices();
      } else {
        setPinModalError(resData.error || 'Incorrect Admin PIN');
      }
    } catch {
      setPinModalError('Failed to verify Admin PIN');
    }
  };

  useEffect(() => {
    const controller = new AbortController();
    void loadDevices(controller.signal);
    // Poll keepalive devices every 15s
    const timer = setInterval(() => void loadDevices(controller.signal), 15000);
    return () => {
      controller.abort();
      clearInterval(timer);
    };
  }, [loadDevices]);

  const onRename = async (deviceId: string) => {
    if (!editName.trim()) return;
    setBusy(true);
    try {
      const res = await fetch('/api/devices/rename', {
        method: 'POST',
        headers: getAdminHeaders(),
        body: JSON.stringify({ device_id: deviceId, name: editName.trim() }),
      });
      if (res.ok) {
        setEditingId(null);
        setEditName('');
        await loadDevices();
      }
    } catch {
      // silently handle
    } finally {
      setBusy(false);
    }
  };

  const onDelete = async (deviceId: string) => {
    if (!confirm('Forget this device and clear its registered session?')) return;
    setBusy(true);
    try {
      const res = await fetch('/api/devices/delete', {
        method: 'POST',
        headers: getAdminHeaders(),
        body: JSON.stringify({ device_id: deviceId }),
      });
      if (res.ok) {
        await loadDevices();
      }
    } catch {
      // silently handle
    } finally {
      setBusy(false);
    }
  };

  const filteredDevices = (data?.devices ?? []).filter((d) => {
    if (filter === 'active') return d.is_active;
    if (filter === 'offline') return !d.is_active;
    return true;
  });

  const handleLockFleet = async () => {
    if (typeof sessionStorage !== 'undefined') {
      sessionStorage.removeItem('ms_admin_pin');
      sessionStorage.removeItem('ms_admin_unlocked');
    }
    setIsFleetUnlocked(false);
    await loadDevices();
  };

  const hasStoredPin = Boolean(getStoredAdminPin());
  const isSingleCurrentDevice = Boolean(data && data.devices.length === 1 && data.devices[0].is_current);
  const isPrivacyScoped = isSingleCurrentDevice && !hasStoredPin && !isFleetUnlocked;

  return (
    <div className="mx-auto max-w-4xl space-y-8 animate-fade-in pb-12">
      {/* Header Profile Section */}
      <section className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-4">
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
          <div>
            <div className="flex items-center gap-2.5">
              <span className="flex h-9 w-9 items-center justify-center rounded-2xl bg-sky-500/15 text-sky-400 border border-sky-500/30">
                <Icon name="devices" size={18} />
              </span>
              <h1 className="text-2xl font-bold tracking-tight text-white">
                Client Devices &amp; Telemetry
              </h1>
            </div>
            <p className="mt-1 text-sm text-white/60">
              Live presence, network ingress, and watch activity across all connected browsers, TVs, and mobile clients.
            </p>
          </div>

          <div className="flex flex-wrap items-center gap-2 self-start sm:self-auto">
            {isPrivacyScoped ? (
              <button
                type="button"
                onClick={() => setShowPinModal(true)}
                className="card-ring rounded-full border border-amber-500/30 bg-amber-500/10 hover:bg-amber-500/20 px-3.5 py-2 text-xs font-semibold text-amber-300 hover:text-amber-200 transition flex items-center gap-1.5 cursor-pointer shadow-sm active:scale-95"
                title="Unlock full fleet telemetry across all household devices with Admin PIN"
              >
                <Icon name="shield" size={13} />
                <span>Unlock Fleet Telemetry</span>
              </button>
            ) : (
              <div className="flex items-center gap-2">
                <span className="flex items-center gap-1.5 rounded-full border border-emerald-500/40 bg-emerald-500/10 px-3.5 py-2 text-xs font-semibold text-emerald-300 shadow-sm">
                  <Icon name="shield" size={13} />
                  <span>Fleet Admin View</span>
                </span>
                <button
                  type="button"
                  onClick={() => void handleLockFleet()}
                  className="card-ring rounded-full border border-rose-500/30 bg-rose-500/10 hover:bg-rose-500/20 px-3.5 py-2 text-xs font-semibold text-rose-300 hover:text-rose-200 transition flex items-center gap-1.5 cursor-pointer shadow-sm active:scale-95"
                  title="Lock fleet telemetry and restore privacy scoping"
                >
                  <Icon name="lock" size={13} />
                  <span>Lock Fleet</span>
                </button>
              </div>
            )}

            <NavLink
              to="/account"
              className="card-ring rounded-full border border-white/15 bg-white/5 px-4 py-2 text-xs font-semibold text-white/80 hover:bg-white/10 hover:text-white transition"
            >
              Pair New TV App →
            </NavLink>
          </div>
        </div>

        {/* Fleet Privacy Scoping Notice */}
        {isPrivacyScoped ? (
          <div className="rounded-2xl border border-amber-500/20 bg-amber-500/[0.04] p-4 text-xs text-amber-200/80 flex items-start gap-3 animate-fade-in">
            <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-xl bg-amber-500/15 text-amber-400 text-sm">
              🛡️
            </span>
            <div className="space-y-0.5">
              <span className="font-semibold text-amber-200 block">Fleet Privacy Scoping Active</span>
              <p className="text-white/60">
                Displaying telemetry and playback history for your current device only. Server administrators can unlock complete household fleet presence with the Admin PIN.
              </p>
            </div>
          </div>
        ) : null}

        {/* Live Vitals Metric Cards */}
        {data ? (
          <div className="grid grid-cols-3 gap-3 pt-2">
            <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4 text-center">
              <span className="block text-2xl font-extrabold text-white">{data.stats.total_devices}</span>
              <span className="text-xs text-white/50">Total Devices</span>
            </div>
            <div className="rounded-2xl border border-emerald-500/30 bg-emerald-500/10 p-4 text-center">
              <span className="block text-2xl font-extrabold text-emerald-400">{data.stats.active_now}</span>
              <span className="text-xs text-emerald-300/80 font-medium">Active Now</span>
            </div>
            <div className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-4 text-center">
              <span className="block text-2xl font-extrabold text-white/50">{data.stats.offline}</span>
              <span className="text-xs text-white/40">Offline</span>
            </div>
          </div>
        ) : null}

        {/* Educational Callout */}
        <div className="rounded-2xl border border-white/10 bg-white/[0.03] p-4 text-xs text-white/70 space-y-1.5">
          <div className="flex items-center gap-2 font-semibold text-white">
            <span className="text-brand-400">💡</span>
            <span>How Device Pairing &amp; Watch History Work</span>
          </div>
          <p>
            <strong>Browser vs. External Screens:</strong> Your web browser signs in directly with your Google account.
            To connect a TV (Android TV or Fire TV Stick) without typing Google passwords with a remote control,
            visit <NavLink to="/account" className="text-brand-400 underline hover:text-brand-300 font-medium">Account &gt; Pair New TV App</NavLink> to mint a pairing token and QR code.
          </p>
          <p className="text-white/50">
            All playback progress, resume positions, and watch history are synchronized automatically across your account and all paired devices.
          </p>
        </div>
      </section>

      {/* Filter Tabs & Device List */}
      <section className="glass-card rounded-3xl p-6 sm:p-8 shadow-xl space-y-6">
        <div className="flex flex-wrap items-center justify-between gap-4 border-b border-white/10 pb-4">
          <div className="flex items-center gap-2">
            {(['all', 'active', 'offline'] as const).map((t) => (
              <button
                key={t}
                type="button"
                onClick={() => setFilter(t)}
                className={`rounded-full px-4 py-1.5 text-xs font-semibold capitalize transition ${
                  filter === t
                    ? 'bg-brand-500 text-white shadow-sm'
                    : 'bg-white/5 text-white/60 hover:bg-white/10 hover:text-white'
                }`}
              >
                {t === 'all' ? 'All Devices' : t === 'active' ? 'Active Now' : 'Offline'}
              </button>
            ))}
          </div>

          <button
            type="button"
            onClick={() => void loadDevices()}
            disabled={loading}
            className="flex items-center gap-1.5 text-xs text-white/50 hover:text-white transition"
          >
            <Icon name="refresh" className={loading ? 'animate-spin' : ''} />
            <span>Refresh</span>
          </button>
        </div>

        {error ? (
          <div className="rounded-2xl border border-rose-500/30 bg-rose-500/10 p-4 text-xs font-medium text-rose-300">
            Failed to load devices: {error}
          </div>
        ) : null}

        {loading && !data ? (
          <div className="py-12 flex flex-col items-center justify-center space-y-3">
            <div className="h-7 w-7 rounded-full border-2 border-white/10 border-t-brand-500 animate-spin" />
            <p className="text-xs text-white/50 animate-pulse">Scanning connected clients…</p>
          </div>
        ) : filteredDevices.length === 0 ? (
          <div className="rounded-2xl border border-dashed border-white/10 p-10 text-center space-y-1">
            <p className="text-sm font-semibold text-white/70">No devices in this view.</p>
            <p className="text-xs text-white/40">Connected clients and streaming sessions will appear here.</p>
          </div>
        ) : (
          <div className="space-y-3.5">
            {filteredDevices.map((d) => (
              <div
                key={d.device_id}
                className="rounded-2xl border border-white/10 bg-obsidian-900/60 p-5 shadow-sm space-y-3 transition hover:border-white/20"
              >
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="flex items-center gap-3">
                    <span className="text-2xl p-2 rounded-xl bg-white/5 border border-white/10">
                      {d.device_icon || '💻'}
                    </span>
                    <div>
                      <div className="flex items-center gap-2">
                        {editingId === d.device_id ? (
                          <div className="flex items-center gap-2">
                            <input
                              value={editName}
                              onChange={(e) => setEditName(e.target.value)}
                              placeholder={d.display_name}
                              className="rounded-lg border border-white/20 bg-obsidian-850 px-3 py-1 text-xs text-white"
                              autoFocus
                            />
                            <button
                              type="button"
                              disabled={busy}
                              onClick={() => void onRename(d.device_id)}
                              className="rounded-lg bg-brand-500 px-2.5 py-1 text-xs font-semibold text-white"
                            >
                              Save
                            </button>
                            <button
                              type="button"
                              onClick={() => setEditingId(null)}
                              className="text-xs text-white/40 hover:text-white"
                            >
                              ✕
                            </button>
                          </div>
                        ) : (
                          <>
                            <h3 className="font-bold text-white text-sm sm:text-base">{d.display_name}</h3>
                            <button
                              type="button"
                              onClick={() => {
                                setEditingId(d.device_id);
                                setEditName(d.display_name);
                              }}
                              className="text-white/40 hover:text-white transition"
                              title="Rename device"
                            >
                              <Icon name="pen" size={13} />
                            </button>
                          </>
                        )}
                        {d.is_current ? (
                          <span className="rounded-full bg-brand-500/20 border border-brand-500/30 px-2 py-0.5 text-[10px] font-bold text-brand-300">
                            THIS BROWSER
                          </span>
                        ) : null}
                      </div>
                      <p className="text-xs text-white/50">
                        {d.browser} • {d.device_os} • {d.device_type}
                      </p>
                    </div>
                  </div>

                  <div className="flex items-center gap-2">
                    <span
                      className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-semibold ${
                        d.is_active
                          ? 'bg-emerald-500/20 text-emerald-300 border border-emerald-500/30'
                          : 'bg-white/10 text-white/50'
                      }`}
                    >
                      <span
                        className={`h-2 w-2 rounded-full ${
                          d.is_active ? 'bg-emerald-400 animate-pulse' : 'bg-white/30'
                        }`}
                      />
                      {d.is_active ? 'Active Now' : 'Offline'}
                    </span>

                    {!d.is_current ? (
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => void onDelete(d.device_id)}
                        className="rounded-full p-1.5 text-white/40 hover:bg-rose-500/15 hover:text-rose-300 transition"
                        title="Forget device"
                      >
                        <Icon name="x" size={14} />
                      </button>
                    ) : null}
                  </div>
                </div>

                {/* Connection & Network Metadata */}
                <div className="grid grid-cols-2 sm:grid-cols-4 gap-2 text-[11px] text-white/50 border-t border-white/5 pt-3">
                  <div>
                    <span className="block text-white/30">Network IP</span>
                    <span className="text-white/70 font-mono">{d.client_ip}</span>
                  </div>
                  <div>
                    <span className="block text-white/30">Route</span>
                    <span className="text-white/70 truncate block">{d.connection_type}</span>
                  </div>
                  <div>
                    <span className="block text-white/30">ISP &amp; Location</span>
                    <span className="text-white/70 truncate block">{d.city || d.isp || 'Localhost'}</span>
                  </div>
                  <div>
                    <span className="block text-white/30">Last Active</span>
                    <span className="text-white/70">{d.last_seen || 'Recently'}</span>
                  </div>
                </div>

                {/* Watch Activity */}
                {(d.recent_watch || (d.watch_history && d.watch_history.length > 0)) ? (
                  <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-2 rounded-xl border border-white/5 bg-white/[0.02] px-3.5 py-2.5 text-xs">
                    <div className="flex items-center gap-2 truncate max-w-[75%]">
                      <span className="text-white/40 shrink-0">🎬</span>
                      <span className="text-white/70 truncate">
                        {d.recent_watch ? (
                          <>
                            Recent: <strong className="text-white font-medium">{('title' in d.recent_watch && d.recent_watch.title) || d.recent_watch.filename}</strong>
                            <span className="ml-2 font-semibold text-brand-400">{d.recent_watch.percent}%</span>
                          </>
                        ) : (
                          <span>{d.watch_history?.length} watched titles recorded</span>
                        )}
                      </span>
                    </div>
                    <button
                      type="button"
                      onClick={() => setSelectedDeviceHistory(d)}
                      className="card-ring self-start sm:self-auto inline-flex items-center gap-1.5 rounded-full border border-white/15 bg-white/5 px-3 py-1 text-xs font-semibold text-white/80 hover:bg-white/10 hover:text-white transition whitespace-nowrap active:scale-95"
                    >
                      <span>📜 Watch History</span>
                      <span className="rounded-full bg-brand-500/20 px-1.5 py-0.2 text-[10px] font-bold text-brand-300 border border-brand-500/30">
                        {d.total_watched || d.watch_history?.length || 0}
                      </span>
                    </button>
                  </div>
                ) : null}
              </div>
            ))}
          </div>
        )}
      </section>

      {/* Portaled Watch History Modal */}
      {selectedDeviceHistory ? createPortal(
        <div
          role="dialog"
          aria-modal="true"
          aria-labelledby="watch-history-title"
          className="fixed inset-0 z-50 flex items-center justify-center p-4 overflow-y-auto bg-black/80 backdrop-blur-md animate-fade-in"
          onClick={() => setSelectedDeviceHistory(null)}
        >
          <div
            className="glass-card relative my-auto w-full max-w-2xl rounded-3xl border border-white/15 bg-obsidian-950 p-6 sm:p-8 shadow-2xl space-y-6"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between gap-4 border-b border-white/10 pb-4">
              <div className="min-w-0">
                <div className="flex items-center gap-2">
                  <span className="text-xl">{selectedDeviceHistory.device_icon}</span>
                  <h2 id="watch-history-title" className="text-xl font-bold text-white truncate">
                    {selectedDeviceHistory.display_name}
                  </h2>
                </div>
                <p className="mt-1 text-xs text-white/50">
                  {selectedDeviceHistory.watch_history?.length ?? 0} titles recorded on this device · Synced with your profile
                </p>
              </div>
              <button
                type="button"
                onClick={() => setSelectedDeviceHistory(null)}
                className="rounded-full p-2 text-white/40 hover:bg-white/10 hover:text-white transition"
                aria-label="Close dialog"
              >
                <Icon name="x" size={18} />
              </button>
            </div>

            <div className="max-h-[60vh] overflow-y-auto pr-1 space-y-3 custom-scrollbar">
              {!selectedDeviceHistory.watch_history || selectedDeviceHistory.watch_history.length === 0 ? (
                <div className="py-12 text-center text-sm text-white/40">
                  No watch history recorded on this device yet.
                </div>
              ) : (
                selectedDeviceHistory.watch_history.map((item, idx) => (
                  <div
                    key={`${item.filename}-${idx}`}
                    className="flex items-center gap-3.5 rounded-2xl border border-white/10 bg-white/[0.03] p-3 transition hover:bg-white/[0.06]"
                  >
                    <div className="h-16 w-11 shrink-0 overflow-hidden rounded-xl bg-obsidian-900 border border-white/10 flex items-center justify-center">
                      {item.poster_url ? (
                        <img
                          src={item.poster_url}
                          alt={item.title}
                          className="h-full w-full object-cover"
                          loading="lazy"
                        />
                      ) : (
                        <Icon name="play" size={16} className="text-white/20" />
                      )}
                    </div>

                    <div className="min-w-0 flex-1 space-y-1.5">
                      <div className="flex items-center justify-between gap-2">
                        <h4 className="font-bold text-white text-sm truncate" title={item.title}>
                          {item.title}
                        </h4>
                        {item.completed ? (
                          <span className="shrink-0 rounded-full bg-emerald-500/20 border border-emerald-500/30 px-2 py-0.5 text-[10px] font-bold text-emerald-300">
                            Completed
                          </span>
                        ) : (
                          <span className="shrink-0 rounded-full bg-brand-500/20 border border-brand-500/30 px-2 py-0.5 text-[10px] font-bold text-brand-300">
                            {item.percent}%
                          </span>
                        )}
                      </div>

                      {/* Progress bar */}
                      <div className="h-1.5 w-full rounded-full bg-white/10 overflow-hidden">
                        <div
                          className={`h-full rounded-full ${item.completed ? 'bg-emerald-400' : 'brand-gradient'}`}
                          style={{ width: `${Math.min(100, Math.max(0, item.percent))}%` }}
                        />
                      </div>

                      <div className="flex items-center justify-between text-[11px] text-white/50">
                        <span>
                          {item.position_str} / {item.duration_str}
                        </span>
                        <span>{item.last_watched_ago}</span>
                      </div>
                    </div>
                  </div>
                ))
              )}
            </div>

            <div className="border-t border-white/10 pt-4 flex justify-end">
              <button
                type="button"
                onClick={() => setSelectedDeviceHistory(null)}
                className="card-ring rounded-full border border-white/15 bg-white/5 px-5 py-2 text-xs font-semibold text-white/80 hover:bg-white/10 hover:text-white transition"
              >
                Close
              </button>
            </div>
          </div>
        </div>,
        document.body
      ) : null}

      {/* Fleet Telemetry Admin PIN Unlock Dialog */}
      {showPinModal && typeof document !== 'undefined'
        ? createPortal(
            <div
              role="dialog"
              aria-modal="true"
              aria-labelledby="fleet-pin-modal-title"
              className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-md overflow-y-auto animate-overlay-fade"
              onClick={(e) => {
                if (e.target === e.currentTarget) setShowPinModal(false);
              }}
            >
              <div
                className="relative w-full max-w-sm my-auto rounded-3xl border border-brand-500/40 bg-obsidian-950 p-6 shadow-2xl space-y-4 animate-scale-in"
                onClick={(e) => e.stopPropagation()}
              >
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2.5">
                    <span className="flex h-9 w-9 items-center justify-center rounded-2xl bg-brand-500/20 text-brand-400 border border-brand-500/40">
                      <Icon name="shield" size={18} />
                    </span>
                    <div>
                      <h3 id="fleet-pin-modal-title" className="font-bold text-white text-base">Unlock Fleet Telemetry</h3>
                      <p className="text-xs text-white/50">Enter your 4-digit PIN</p>
                    </div>
                  </div>
                  <button
                    type="button"
                    onClick={() => setShowPinModal(false)}
                    className="text-white/40 hover:text-white cursor-pointer"
                    aria-label="Close dialog"
                  >
                    ✕
                  </button>
                </div>

                {pinModalError ? (
                  <div className="rounded-xl border border-rose-500/30 bg-rose-500/10 p-3 text-xs text-rose-300">
                    ⚠️ {pinModalError}
                  </div>
                ) : null}

                <form
                  onSubmit={(e) => {
                    e.preventDefault();
                    void handleVerifyFleetPin(pinInputValue);
                  }}
                  className="space-y-4"
                >
                  <input
                    type="password"
                    maxLength={8}
                    autoFocus
                    value={pinInputValue}
                    onChange={(e) => setPinInputValue(e.target.value)}
                    placeholder="Admin PIN…"
                    className="w-full text-center tracking-widest text-lg rounded-xl border border-white/20 bg-obsidian-900 py-2.5 px-4 text-white focus:border-brand-500 focus:outline-none"
                  />

                  <div className="flex items-center justify-end gap-2.5">
                    <button
                      type="button"
                      onClick={() => setShowPinModal(false)}
                      className="rounded-full border border-white/15 bg-white/5 px-4 py-2 text-xs font-semibold text-white/80 hover:bg-white/10 cursor-pointer"
                    >
                      Cancel
                    </button>
                    <button
                      type="submit"
                      disabled={!pinInputValue}
                      className="rounded-full brand-gradient px-5 py-2 text-xs font-bold text-white shadow-md disabled:opacity-40 cursor-pointer"
                    >
                      Unlock Fleet
                    </button>
                  </div>
                </form>
              </div>
            </div>,
            document.body
          )
        : null}
    </div>
  );
}

export default DevicesPage;
