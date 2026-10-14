import { useCallback, useEffect, useState } from 'react';
import { NavLink } from 'react-router';
import { Icon } from '../../components/icons';

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
  recent_watch?: {
    filename: string;
    percent: number;
  } | null;
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

  const loadDevices = useCallback(async () => {
    try {
      const res = await fetch('/api/devices');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const body = (await res.json()) as DevicesResponse;
      setData(body);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadDevices();
    // Poll keepalive devices every 15s
    const timer = setInterval(() => void loadDevices(), 15000);
    return () => clearInterval(timer);
  }, [loadDevices]);

  const onRename = async (deviceId: string) => {
    if (!editName.trim()) return;
    setBusy(true);
    try {
      const res = await fetch('/api/devices/rename', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
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
      const res = await fetch(`/api/devices/${encodeURIComponent(deviceId)}`, {
        method: 'DELETE',
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

          <div className="flex items-center gap-2 self-start sm:self-auto">
            <NavLink
              to="/account"
              className="card-ring rounded-full border border-white/15 bg-white/5 px-4 py-2 text-xs font-semibold text-white/80 hover:bg-white/10 hover:text-white transition"
            >
              Pair New TV App →
            </NavLink>
          </div>
        </div>

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
                {d.recent_watch ? (
                  <div className="rounded-xl border border-white/5 bg-white/[0.02] px-3 py-2 flex items-center justify-between text-xs">
                    <span className="text-white/60 truncate max-w-[80%]">
                      🎬 Recent: <strong>{d.recent_watch.filename}</strong>
                    </span>
                    <span className="font-semibold text-brand-400">{d.recent_watch.percent}%</span>
                  </div>
                ) : null}
              </div>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}

export default DevicesPage;
