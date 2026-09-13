# Media Server Performance Model

## Resource priority

The media server is designed around this priority order:

1. Active media streaming
2. Uploads and user-triggered transcoding
3. Other interactive requests
4. Scanner and metadata work
5. Automatic pre-cache transcoding

This is a scheduling preference, not a hard CPU or GPU quota. Interactive work must remain responsive, while background work may use substantial resources when the machine is otherwise idle.

## Gunicorn

Production defaults are 2 Gunicorn workers with 4 gthread threads per worker. These values can be overridden with `GUNICORN_WORKERS` and `GUNICORN_THREADS`.

## Automatic transcoding

Automatic pre-cache HLS transcoding is deliberately deprioritized at the FFmpeg process level. The worker lowers CPU scheduling priority and, on Linux systems with `ionice`, assigns the FFmpeg process to the idle I/O class.

Interactive HLS/direct transcoding is not given this background priority and therefore remains at the normal process priority.

This does **not** cap FFmpeg CPU usage and does not impose a fixed GPU limit. A background transcode can still consume available CPU/GPU capacity when interactive work does not need it.

## Verification

Check the Gunicorn layout:

```bash
ps -eo pid,ppid,ni,pcpu,pmem,cmd | grep -E 'gunicorn|app.py' | grep -v grep
```

Workers should normally have `NI=0`.

Check FFmpeg scheduling during automatic pre-cache work:

```bash
ps -eo pid,ppid,ni,pcpu,pmem,cmd | grep ffmpeg | grep -v grep
```

An automatic background FFmpeg process should normally show a positive nice value (currently `NI=10`). Interactive FFmpeg should remain at the normal nice level.

For VA-API systems, GPU utilization can be observed separately with the appropriate DRM/VA-API monitoring tools. Process nice/ionice controls CPU and I/O scheduling; it is not a GPU quota mechanism.
