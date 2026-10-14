/**
 * Typed client for LAN Cast & DLNA Remote Playback endpoints (/api/cast/*).
 */
import { request } from './client';

export interface CastDevice {
  readonly id: string;
  readonly name: string;
  readonly kind: 'dlna' | 'cast';
  readonly model?: string;
  readonly manufacturer?: string;
  readonly ip?: string;
  readonly host?: string;
  readonly location?: string;
}

export interface CastDevicesResponse {
  readonly ok: boolean;
  readonly devices: CastDevice[];
  readonly scanning: boolean;
  readonly errors?: Record<string, string>;
  readonly scanned_at?: number;
}

export interface CastPlayResponse {
  readonly ok: boolean;
  readonly device?: string;
  readonly url?: string;
  readonly kind?: string;
  readonly error?: string;
}

export interface CastControlResponse {
  readonly ok: boolean;
  readonly error?: string;
}

export type CastState = 'playing' | 'paused' | 'buffering' | 'stopped' | 'unknown';

export interface CastSubtitleTrack {
  readonly track_id: number;
  readonly label: string;
  readonly lang: string;
}

export interface CastStatusResponse {
  readonly ok: boolean;
  readonly state?: CastState;
  readonly position?: number;
  readonly duration?: number;
  readonly volume?: number;
  readonly muted?: boolean;
  readonly title?: string;
  readonly subtitles?: CastSubtitleTrack[];
  readonly active_subtitle_id?: number;
  readonly subtitle_offset?: number;
  readonly error?: string;
}

export function getCastDevices(
  options: { force?: boolean; signal?: AbortSignal } = {},
): Promise<CastDevicesResponse> {
  const url = options.force ? '/api/cast/devices?refresh=1' : '/api/cast/devices';
  return request<CastDevicesResponse>(url, { signal: options.signal, timeoutMs: 10_000 });
}

export function startCastPlay(
  deviceId: string,
  filename: string,
  options: { position?: number; origin?: string; subtitle_offset?: number; signal?: AbortSignal } = {},
): Promise<CastPlayResponse> {
  return request<CastPlayResponse>('/api/cast/play', {
    method: 'POST',
    body: {
      device_id: deviceId,
      filename,
      position: options.position,
      origin: options.origin,
      subtitle_offset: options.subtitle_offset,
    },
    signal: options.signal,
    timeoutMs: 15_000,
  });
}

export function sendCastControl(
  deviceId: string,
  action: 'play' | 'pause' | 'stop' | 'seek' | 'volume' | 'mute' | 'subtitle' | 'subtitle_offset',
  value?: number | boolean,
  options: { signal?: AbortSignal } = {},
): Promise<CastControlResponse> {
  return request<CastControlResponse>('/api/cast/control', {
    method: 'POST',
    body: {
      device_id: deviceId,
      action,
      value,
    },
    signal: options.signal,
    timeoutMs: 8_000,
  });
}

export function getCastStatus(
  deviceId: string,
  options: { signal?: AbortSignal } = {},
): Promise<CastStatusResponse> {
  const query = new URLSearchParams({ device_id: deviceId });
  return request<CastStatusResponse>(`/api/cast/status?${query}`, {
    signal: options.signal,
    timeoutMs: 8_000,
  });
}

export function stopCast(
  deviceId: string,
  options: { signal?: AbortSignal } = {},
): Promise<CastControlResponse> {
  return sendCastControl(deviceId, 'stop', undefined, options);
}
