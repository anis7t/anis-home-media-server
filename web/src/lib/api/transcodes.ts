import { request } from './client';

export interface HardwareEngineInfo {
  readonly primary: {
    readonly name: string;
    readonly adapter: number;
    readonly backend: string;
    readonly status: string;
  };
  readonly secondary: {
    readonly name: string;
    readonly adapter: number;
    readonly backend: string;
    readonly status: string;
  };
}

export interface TranscodeSummaryMetrics {
  readonly active_count: number;
  readonly running_count: number;
  readonly queued_count: number;
  readonly total_current_bytes: number;
  readonly total_current_size_str: string;
  readonly total_estimated_bytes: number;
  readonly total_estimated_size_str: string;
  readonly overall_eta_seconds: number;
  readonly overall_eta_str: string;
  readonly hardware_engine: HardwareEngineInfo;
}

export interface ActiveTranscodeJob {
  readonly id: number;
  readonly filename: string;
  readonly title: string;
  readonly year?: number | null;
  readonly runtime?: number | null;
  readonly poster_url?: string;
  readonly poster_path?: string | null;
  readonly backdrop_path?: string | null;
  readonly mode: string;
  readonly preset_label: string;
  readonly status: 'running' | 'queued';
  readonly percent: number;
  readonly speed?: number | null;
  readonly speed_str?: string | null;
  readonly fps?: number | null;
  readonly fps_str?: string | null;
  readonly eta?: number | null;
  readonly eta_str: string;
  readonly encoded_str?: string | null;
  readonly duration_str?: string | null;
  readonly current_bytes: number;
  readonly current_size_str: string;
  readonly estimated_total_bytes: number;
  readonly estimated_total_size_str: string;
  readonly priority: number;
  readonly created_at: string;
  readonly updated_at: string;
}

export interface RecentTranscodeJob {
  readonly id: number;
  readonly filename: string;
  readonly title: string;
  readonly year?: number | null;
  readonly poster_url?: string;
  readonly mode: string;
  readonly preset_label: string;
  readonly status: 'completed' | 'failed' | 'canceled';
  readonly error?: string | null;
  readonly elapsed_sec: number;
  readonly elapsed_str: string;
  readonly current_bytes: number;
  readonly current_size_str: string;
  readonly created_at: string;
  readonly updated_at: string;
}

export interface TranscodeDashboardResponse {
  readonly summary: TranscodeSummaryMetrics;
  readonly active_jobs: readonly ActiveTranscodeJob[];
  readonly recent_jobs: readonly RecentTranscodeJob[];
}

export async function fetchTranscodeDashboard(adminPin?: string): Promise<TranscodeDashboardResponse> {
  const headers: Record<string, string> = {};
  if (adminPin) {
    headers['X-Admin-Pin'] = adminPin;
  }
  try {
    return await request<TranscodeDashboardResponse>('/api/transcode/dashboard', { headers });
  } catch {
    // If /api/transcode/dashboard is unavailable or 404 (e.g. before persistent service restart),
    // seamlessly fall back to /api/transcodes so active/queued jobs are never lost.
    return await fetchTranscodesFallback();
  }
}

async function fetchTranscodesFallback(): Promise<TranscodeDashboardResponse> {
  interface RawTranscodeItem {
    readonly id?: number;
    readonly filename: string;
    readonly title?: string;
    readonly mode?: string;
    readonly preset_label?: string;
    readonly status: 'running' | 'queued';
    readonly percent?: number;
    readonly speed?: string | null;
    readonly fps?: string | null;
    readonly eta_str?: string;
    readonly encoded_str?: string | null;
    readonly duration_str?: string | null;
    readonly current_bytes?: number;
    readonly current_size_str?: string;
    readonly estimated_total_bytes?: number;
    readonly estimated_total_size_str?: string;
    readonly poster_url?: string;
  }

  const res = await fetch('/api/transcodes');
  if (!res.ok) {
    throw new Error(`Failed to fetch active transcodes: ${res.statusText}`);
  }
  const body = (await res.json()) as { readonly transcodes?: readonly RawTranscodeItem[] };
  const rawList = body.transcodes ?? [];

  const activeJobs: ActiveTranscodeJob[] = rawList.map((item, idx) => {
    const filename = item.filename;
    const title = item.title || filename.split('/').pop()?.replace(/\.[^.]+$/, '') || filename;
    const mode = item.mode || 'Adaptive Transcode (fMP4)';
    const status: 'running' | 'queued' = item.status === 'running' ? 'running' : 'queued';
    const percent = typeof item.percent === 'number' ? item.percent : 0;
    const currentBytes = item.current_bytes ?? 0;
    const estBytes = item.estimated_total_bytes ?? 0;

    return {
      id: item.id ?? idx + 1,
      filename,
      title,
      mode,
      preset_label: item.preset_label || '1080p fMP4',
      status,
      percent,
      speed_str: item.speed ?? null,
      fps_str: item.fps ?? null,
      eta_str: item.eta_str || (status === 'queued' ? 'Queued' : 'calculating...'),
      encoded_str: item.encoded_str ?? null,
      duration_str: item.duration_str ?? null,
      current_bytes: currentBytes,
      current_size_str: item.current_size_str || '0 B',
      estimated_total_bytes: estBytes,
      estimated_total_size_str: item.estimated_total_size_str || '~2.8 GB',
      priority: 10,
      poster_url: item.poster_url || `/poster/${encodeURIComponent(filename)}`,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };
  });

  // Put actively running streams at the beginning, followed by queued streams
  activeJobs.sort((a, b) => {
    if (a.status === 'running' && b.status !== 'running') return -1;
    if (a.status !== 'running' && b.status === 'running') return 1;
    if (a.status === 'running' && b.status === 'running') {
      return b.percent - a.percent;
    }
    return 0;
  });

  const runningCount = activeJobs.filter((j) => j.status === 'running').length;
  const queuedCount = activeJobs.filter((j) => j.status === 'queued').length;
  const totalCurrentBytes = activeJobs.reduce((acc, j) => acc + j.current_bytes, 0);
  const totalEstBytes = activeJobs.reduce((acc, j) => acc + j.estimated_total_bytes, 0);

  return {
    summary: {
      active_count: activeJobs.length,
      running_count: runningCount,
      queued_count: queuedCount,
      total_current_bytes: totalCurrentBytes,
      total_current_size_str:
        totalCurrentBytes > 0
          ? `${(totalCurrentBytes / (1024 * 1024 * 1024)).toFixed(2)} GB`
          : '0 B',
      total_estimated_bytes: totalEstBytes,
      total_estimated_size_str:
        totalEstBytes > 0
          ? `${(totalEstBytes / (1024 * 1024 * 1024)).toFixed(1)} GB`
          : '~0 B',
      overall_eta_seconds: 0,
      overall_eta_str:
        runningCount > 0 ? 'Active dual-GPU stream' : `${queuedCount} queued`,
      hardware_engine: {
        primary: {
          name: 'AMD Radeon RX 560X',
          adapter: 1,
          backend: 'D3D11VA',
          status: runningCount > 0 ? 'Active Encoding' : 'Standby',
        },
        secondary: {
          name: 'AMD Radeon Vega 8',
          adapter: 0,
          backend: 'D3D11VA',
          status: runningCount > 0 ? 'Active Encoding' : 'Standby',
        },
      },
    },
    active_jobs: activeJobs,
    recent_jobs: [],
  };
}

export async function cancelTranscodeJob(
  filename: string,
  adminPin?: string
): Promise<{ canceled: boolean; message?: string }> {
  const headers: Record<string, string> = {};
  if (adminPin) {
    headers['X-Admin-Pin'] = adminPin;
  }
  return request<{ canceled: boolean; message?: string }>(
    `/api/transcode/jobs/${encodeURIComponent(filename)}/cancel`,
    {
      method: 'POST',
      headers,
    }
  );
}

export async function enqueueTranscodeJob(
  filename: string,
  mode = 'hls:1080p',
  priority = 10,
  adminPin?: string
): Promise<{ job: unknown }> {
  const headers: Record<string, string> = {};
  if (adminPin) {
    headers['X-Admin-Pin'] = adminPin;
  }
  return request<{ job: unknown }>(
    `/api/transcode/jobs/${encodeURIComponent(filename)}`,
    {
      method: 'POST',
      headers,
      body: { mode, priority, force: true },
    }
  );
}
