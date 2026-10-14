import { useEffect, useRef, useState } from 'react';
import { Icon } from '../../components/icons';
import { getCastDevices, type CastDevice } from '../../lib/api/cast';

export interface CastModalProps {
  open: boolean;
  onClose: () => void;
  onSelectDevice: (device: CastDevice) => void;
  onDisconnectDevice?: () => void;
  connectingDeviceId?: string | null;
  activeDeviceId?: string | null;
}

export function CastModal({
  open,
  onClose,
  onSelectDevice,
  onDisconnectDevice,
  connectingDeviceId,
  activeDeviceId,
}: CastModalProps) {
  const [devices, setDevices] = useState<CastDevice[]>([]);
  const [scanning, setScanning] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const pollTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const stopPolling = () => {
    if (pollTimerRef.current) {
      clearTimeout(pollTimerRef.current);
      pollTimerRef.current = null;
    }
  };

  const fetchDevices = async (force = false) => {
    stopPolling();
    setScanning(true);
    setError(null);
    try {
      const res = await getCastDevices({ force });
      if (res && res.devices) {
        setDevices(res.devices);
      }
      if (res?.scanning) {
        let attempts = 0;
        const poll = async () => {
          attempts += 1;
          try {
            const nextRes = await getCastDevices({ force: false });
            if (nextRes && nextRes.devices) {
              setDevices(nextRes.devices);
            }
            if (nextRes?.scanning && attempts < 10) {
              pollTimerRef.current = setTimeout(poll, 1000);
            } else {
              setScanning(false);
            }
          } catch {
            setScanning(false);
          }
        };
        pollTimerRef.current = setTimeout(poll, 1000);
      } else {
        setScanning(false);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to scan for LAN devices');
      setScanning(false);
    }
  };

  useEffect(() => {
    if (!open) {
      stopPolling();
      return;
    }
    void fetchDevices(false);

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        onClose();
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => {
      stopPolling();
      window.removeEventListener('keydown', handleKeyDown);
    };
  }, [open]);

  if (!open) return null;

  return (
    <div
      id="castModal"
      className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-md animate-fade-in"
      role="dialog"
      aria-modal="true"
      aria-labelledby="castModalTitle"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="relative w-full max-w-md rounded-2xl sm:rounded-3xl bg-neutral-950/95 ring-1 ring-white/10 shadow-2xl p-6 sm:p-7 overflow-hidden text-white">
        {/* Ambient glow */}
        <div className="pointer-events-none absolute -top-24 -right-24 h-48 w-48 rounded-full bg-brand-600/20 blur-3xl" />

        {/* Header */}
        <div className="flex items-center justify-between pb-4 border-b border-white/10">
          <div className="flex items-center gap-2.5">
            <span className="flex h-9 w-9 items-center justify-center rounded-xl bg-brand-500/15 text-brand-400 border border-brand-500/30">
              <Icon name="cast" size={18} />
            </span>
            <div>
              <h2 id="castModalTitle" className="text-base sm:text-lg font-bold tracking-tight">
                Cast to Device
              </h2>
              <p className="text-xs text-white/50">Play on Smart TV, Chromecast, or DLNA</p>
            </div>
          </div>

          <div className="flex items-center gap-1.5">
            <button
              type="button"
              onClick={() => void fetchDevices(true)}
              disabled={scanning}
              title="Rescan network for devices"
              className="flex h-8 w-8 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/70 transition hover:bg-white/10 hover:text-white disabled:opacity-40"
            >
              <Icon name="refresh" size={13} className={scanning ? 'animate-spin' : ''} />
            </button>
            <button
              type="button"
              onClick={onClose}
              title="Close modal (Esc)"
              className="flex h-8 w-8 items-center justify-center rounded-full border border-white/15 bg-white/5 text-white/70 transition hover:bg-white/10 hover:text-white"
            >
              <Icon name="x" size={14} />
            </button>
          </div>
        </div>

        {/* Active connection notice */}
        {activeDeviceId && (
          <div className="mt-4 p-3 rounded-xl bg-brand-950/40 border border-brand-500/30 flex items-center justify-between">
            <div className="flex items-center gap-2 text-xs text-brand-300 font-medium">
              <span className="h-2 w-2 rounded-full bg-brand-400 animate-pulse" />
              <span>Currently casting</span>
            </div>
            {onDisconnectDevice && (
              <button
                type="button"
                onClick={onDisconnectDevice}
                className="text-xs font-semibold text-rose-400 hover:text-rose-300 transition underline"
              >
                Disconnect
              </button>
            )}
          </div>
        )}

        {/* Device List */}
        <div className="mt-4 max-h-72 overflow-y-auto space-y-2 pr-1 custom-scrollbar">
          {scanning && devices.length === 0 ? (
            <div className="py-10 text-center space-y-2">
              <span className="inline-block animate-spin text-xl">📡</span>
              <p className="text-xs font-medium text-white/60">Scanning Wi-Fi network for TVs & Chromecasts...</p>
            </div>
          ) : devices.length === 0 ? (
            <div className="py-8 text-center space-y-3 px-4">
              <div className="mx-auto flex h-12 w-12 items-center justify-center rounded-full bg-white/5 text-white/30 border border-white/10">
                <Icon name="tv" size={24} />
              </div>
              <div className="space-y-1">
                <p className="text-sm font-semibold text-white/80">No playback devices found</p>
                <p className="text-xs text-white/40 leading-relaxed max-w-xs mx-auto">
                  Make sure your Smart TV or Chromecast is connected to the same local network, then click refresh.
                </p>
              </div>
            </div>
          ) : (
            devices.map((device) => {
              const isConnecting = connectingDeviceId === device.id;
              const isActive = activeDeviceId === device.id;

              return (
                <button
                  key={device.id}
                  type="button"
                  onClick={() => onSelectDevice(device)}
                  disabled={isConnecting}
                  className={`w-full flex items-center justify-between p-3 rounded-xl border text-left transition ${
                    isActive
                      ? 'bg-brand-500/15 border-brand-500/40 text-white'
                      : 'bg-white/5 border-white/10 hover:bg-white/10 hover:border-white/20 text-white/90'
                  }`}
                >
                  <div className="flex items-center gap-3 min-w-0">
                    <span className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border ${
                      device.kind === 'cast'
                        ? 'bg-blue-500/15 border-blue-500/30 text-blue-400'
                        : 'bg-amber-500/15 border-amber-500/30 text-amber-400'
                    }`}>
                      <Icon name={device.kind === 'cast' ? 'cast' : 'tv'} size={18} />
                    </span>
                    <div className="truncate min-w-0">
                      <div className="text-sm font-semibold truncate">{device.name}</div>
                      <div className="text-xs text-white/40 flex items-center gap-2 mt-0.5">
                        <span className="uppercase text-[10px] font-mono tracking-wider px-1.5 py-0.2 rounded bg-white/10">
                          {device.kind === 'cast' ? 'Google Cast' : 'DLNA TV'}
                        </span>
                        {device.model && <span className="truncate">{device.model}</span>}
                        {(device.host || device.ip) && <span className="text-white/30 hidden sm:inline">{device.host || device.ip}</span>}
                      </div>
                    </div>
                  </div>

                  <div className="shrink-0 ml-3">
                    {isConnecting ? (
                      <span className="text-xs text-brand-400 font-medium animate-pulse flex items-center gap-1">
                        <span>Connecting...</span>
                      </span>
                    ) : isActive ? (
                      <span className="text-xs font-semibold text-emerald-400 flex items-center gap-1.5">
                        <span className="h-2 w-2 rounded-full bg-emerald-400" />
                        <span>Active</span>
                      </span>
                    ) : (
                      <span className="text-xs font-medium text-white/50 group-hover:text-white">
                        Connect →
                      </span>
                    )}
                  </div>
                </button>
              );
            })
          )}
        </div>

        {error && (
          <div className="mt-3 p-2.5 rounded-lg bg-rose-500/10 border border-rose-500/30 text-rose-300 text-xs">
            {error}
          </div>
        )}
      </div>
    </div>
  );
}
