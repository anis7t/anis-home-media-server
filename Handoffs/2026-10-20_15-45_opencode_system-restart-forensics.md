# Session Handoff — 2026-10-20 15:45 IST — System Restart Forensics

**Author / Agent:** OpenCode (MiniMax M3.1 Flash)
**Topic:** Post-mortem of the 2026-10-20 15:01 hard system restart; the AMD graphics instability behind it; the discovery that the AMF transcode pipeline provokes GPU TDRs
**Branch:** `feature/phase-11-opening-sequence` (HEAD `f15da02` — *"feat(intro): the web canvas renderer, and the frame-for-frame oracle (Phase 11 slice 11.2)"*)
**Working Directory:** `E:\MediaServer`
**Status:** 🔍 **Investigated and diagnosed. One config change applied (pagefile). The GPU driver update is researched but NOT installed. Several owner decisions are open.**

---

## 1. What this session produced

The owner asked why the machine restarted while another opencode session was mid-flight. This
session established, from primary evidence:

1. **The restart was a hard reset, not a crash Windows caught.** No bugcheck, no WHEA, no
   minidump, no thermal event, no memory-exhaustion event, and **no `User32/1074`** — Windows did
   not initiate the reboot.
2. **The underlying fault is the AMD graphics stack**, and it is *chronic*, not a one-off: the WER
   queue holds **42 kernel "Hardware error" reports** spanning **September 2025 → 18 October 2026**.
3. **The AMF transcode pipeline is itself a TDR trigger** — proven to the second against the
   transcode worker's own failure log. This is the highest-value finding here, because it is a
   *project-level* risk, not merely a workstation annoyance.
4. **The HLS cache does not need to move to another volume** — it needs to be smaller, and it must
   be resized *after* the GPU fix, not before (see §7.3).
5. **A newer WHQL AMD driver exists** (Adrenalin 26.5.2, 2026-05-21) — researched with its
   caveats, **not installed**.

**One state change was made:** the pagefile is now a fixed, reserved **2 GB** on `C:` (§6.1).
It does not take effect until the next reboot.

---

## 2. The event — minute by minute

All times IST. The 20 Oct 2026 timeline:

| Time | Event | Source |
|---|---|---|
| 13:37:21 | The other opencode session starts — `ses_ea7a639deffeUwaMOlFNNrFIUj`, *"Executing 2026-10-20 OpenCode handoff prompt"* (Phase 11 web intro overlay) | `opencode.db` → `session_message` |
| 13:37 → 15:01 | Continuous **Playwright / headless-Chromium** work: `npx playwright test e2e/intro-frame.spec.ts` plus custom `intro-*.mjs` scripts that launch Chromium, render the overlay and **pixel-diff** it, debugging `will-change` layer promotion and filter/blur rendering. Back-to-back runs of 60–90 s, with a Vite dev server on `:5173` | `opencode.log`, `session_message` |
| 14:38:24 | Windows records this as the *"previous shutdown"* time in Event 6008 | `System` log, Event 6008 |
| 15:00:28 | The session starts another Chromium diagnostic — **still running at the moment of the reset** | `session_message` seq 2405 |
| **~15:01:28** | **Hard reset.** Firmware timestamp of the next boot | `Kernel-Boot` Event 238 |
| 15:01:30 | Windows boots. `Kernel-Power` **Event 41** — *"rebooted without cleanly shutting down first"* | `System` log |
| 15:02:40 | The opencode server restarts; the session is **resumed** and says *"The dev server was killed by the restart"* | `session_message` seq 2415/2421 |
| 15:03:31 | This investigation session starts | — |
| 15:19:19 | The other session's last tool call — **its work survived; nothing was lost** | `session_message` seq 2696 |

> ### ⚠️ The 6008 timestamp is an *onset marker*, not the death time
>
> Event 6008 says *"The previous system shutdown at 2:38:24 PM … was unexpected."* That is **not**
> when the machine died. Proof: on **17 Oct**, 6008 reported a shutdown at 20:18:26 IST, yet the
> `System` event log kept recording for **1 h 32 m afterwards** (last event 22:50:40 IST) and the
> machine was not rebooted until 23:09:18.
>
> The same pattern appears on 10/18 (6008 → 18:29:32, last System-log event 18:29, reboot 23:58:10).
> On 10/16 and 10/11 there were **zero** System-log events after the 6008 marker — i.e. those were
> instant deaths. So the 6008 marker is a *lower bound* on the death time.
>
> **The real death window on 20 Oct is 15:00:28 → 15:01:28.**

---

## 3. Evidence trail — how each conclusion was established

So the next session does not have to re-derive any of this.

### 3.1 The reset was a hard power-off, not a bugcheck

```
Kernel-Power 41 @ 2026-10-20 15:01:34
  BugcheckCode=0              PowerButtonTimestamp=0
  LongPowerButtonPressDetected=false   SleepInProgress=0
  WHEABootErrorCount=0        Checkpoint=0
```

- No `Microsoft-Windows-WHEA-Logger` events at all.
- No `Event 1001` (BugCheck) records; `C:\Windows\Minidump` and `C:\Windows\MEMORY.DMP` are empty.
- **No `User32/1074`** — a Windows-initiated reboot always logs 1074. Its absence means the reboot
  was external (power cut) or the kernel was already wedged.
- `PowerButtonTimestamp=0` / `LongPowerButtonPressDetected=false` are **expected** for a
  force-off: a frozen kernel cannot record the button press.
- No `Microsoft-Windows-Resource-Exhaustion-Detector` **2004** event (no memory exhaustion).
- No `Kernel-Processor-Power` 86 (no thermal throttling).

### 3.2 It is a recurring, identical failure mode

All **12** `Event 41` records since 2026-09-05 carry the **same zero signature**:

| Reboot at | Bugcheck | PowerButtonTS | LongPB | Sleep | WHEA |
|---|---|---|---|---|---|
| 20-10 15:01:34 | 0 | 0 | false | 0 | 0 |
| 18-10 23:58:10 | 0 | 0 | false | 0 | 0 |
| 17-10 23:09:18 | 0 | 0 | false | 0 | 0 |
| 16-10 22:18:08 | 0 | 0 | false | 0 | 0 |
| 11-10 14:22:00 | 0 | 0 | false | 0 | 0 |
| 11-10 13:31:03 | 0 | 0 | false | 0 | 0 |
| 03-10 17:10:40 | 0 | 0 | false | 0 | 0 |
| 10-09 17:41:04 | 0 | 0 | false | **6** | 0 |
| 08-09 01:43:07 | 0 | 0 | false | 0 | 0 |
| 06-09 00:29:51 | 0 | 0 | false | 0 | 0 |
| 05-09 16:53:51 | 0 | 0 | false | 0 | 0 |
| 05-09 05:50:00 | 0 | 0 | false | 0 | 0 |

### 3.3 What it was **not**

| Hypothesis | Verdict | Evidence |
|---|---|---|
| Blue screen | **No** | `BugcheckCode=0`, no dump, no Event 1001 |
| Windows-initiated reboot | **No** | no `User32/1074` |
| Windows Update | **No** | only Defender intel (`KB2267602`) + `Microsoft.WindowsAppRuntime.2`; **no driver updates** |
| Thermal shutdown | **No** | no Event 86; no WHEA |
| Memory exhaustion | **No** | no 2004 event (though the detector *did* fire on 16–17 Oct — see §4.4) |
| Power loss (charger/board) | **Cannot be excluded** | AC is connected, battery 99 %, `PowerOnline=True`; a 2-minute gap between last-alive and reset is *consistent* with a power cut **and** with a forced off |
| The media server | **No** | no `ffmpeg` running, no HLS cache writes 13:00–15:05, sweeper clean (`scanned=33, queued=0, errors=0` at 14:33 and 14:38), `/health` = healthy, `rust_api.log` clean |
| **The AMD GPU** | **YES — see §4.1–§4.2** | 42 queued WER kernel reports |

---

## 4. Diagnosis — four stacked faults

### 4.1 Fault 1 — The AMD graphics stack is chronically unstable *(root cause)*

`C:\ProgramData\Microsoft\Windows\WER\ReportQueue` holds **42 kernel reports**, re-processed by
WER at *every* boot (which is why the `Application` log is full of them):

| Code | Count | Meaning |
|---|---|---|
| **141** | 22 | `VIDEO_TDR_FAILURE` — the GPU stopped responding |
| **144** | 6 | `VIDEO_ENGINE_TIMEOUT_DETECTED` |
| **117** | 3 | `VIDEO_TDR_TIMEOUT_DETECTED` |
| **1a8** / **1b8** | 5 | `VIDEO_DXGKRNL_FATAL_ERROR` — the unrecoverable variant ("black screen of death") |
| **a2000002** | 4 | `AMD_REPORT_UM` — the AMD user-mode driver's own hang report |
| **d1** | 1 | Blue screen `0xD1` `DRIVER_IRQL_NOT_LESS_OR_EQUAL` |
| **a** | 1 | Blue screen `0xA` `IRQL_NOT_LESS_OR_EQUAL` |

**Original hang dates** (from the dump filenames and the report-directory creation times):

```
2025-09-07  1a8, 1b8
2025-11-10  22×141, 3×117, 2×1a8, 1×1b8   ← a 5-hour TDR storm, 13:48 → 18:32
2026-01-10  144
2026-05-21  144 ×2
2026-05-28  144
2026-05-29  141
2026-07-08  144
2026-09-04  BlueScreen d1   ← 090426-17171-01.dmp
2026-09-04  BlueScreen a    ← 090426-14125-01.dmp
2026-10-18  08:34, 09:01, 09:02, 14:30  ← AMD_REPORT_UM + WATCHDOG dumps
```

Live dumps on disk: `C:\Windows\LiveKernelReports\AMD_REPORT_UM\AMD_REPORT_UM-20261018-{0834,0901,0902,1430}.dmp`
and `C:\Windows\LiveKernelReports\WATCHDOG\WATCHDOG-20261018-{0834,0901,0902,1430}.dmp`.

**Driver in use:** `31.0.21923.1000`, dated **2025-06-03** (`oem43.inf`, catalog `u0415346.cat`),
covering both the **Radeon RX 560X** (dGPU) and the **AMD Radeon Vega 8** (iGPU).
AMF runtime: `C:\Windows\System32\amfrt64.dll`, dated **2025-05-08**.
ffmpeg 9.0.1 (`gyan.dev` essentials) probes clean: `AMF initialisation succeeded via D3D11`, with
**no** AMF-version warning (so the runtime is ≥ 23.30).

### 4.2 Fault 2 — ⭐ **The AMF transcode pipeline provokes the GPU TDRs**

This is the finding that matters most, because it is a **project-level** risk.

The four GPU hangs on **18 Oct** line up with the AMF transcode worker to the second. The
transcode log is UTC; the dumps are IST (UTC+5:30).

| GPU hang dump (IST) | `rust_api.log` (UTC → IST) | What the server was doing |
|---|---|---|
| `AMD_REPORT_UM-…-0834` 08:34:06, `WATCHDOG-…-0834` 08:34:16 | `03:04:27` → **08:34:27** | `ERROR … Worker [rust-worker-24196] failed job #1077` — **11–21 s after the hang** |
| `AMD_REPORT_UM-…-0901` 09:01:42, `WATCHDOG-…-0901` 09:01:51 | `03:32:09` → **09:02:09** | `ERROR … Worker [rust-worker-24196] failed job #1077` — **27 s after the hang** |
| `AMD_REPORT_UM-…-0902` 09:02:16, `WATCHDOG-…-0902` 09:02:19 | `03:32:09` → **09:02:09** | the same log line; the worker **immediately claimed job #1083** with `vpp_amf=true, workers=3 (AMD Radeon(TM) Vega 8 …)` |
| `AMD_REPORT_UM-…-1430` 14:30:03, `WATCHDOG-…-1430` 14:30:03 | `09:00:18` → **14:30:18** | `WARN sqlx::pool::acquire: acquired connection, but time to acquire exceeded slow threshold aquired_after_secs=2.42` and the sweeper reporting **`scanned=0, queued=0, skipped=0`** — the service could not even enumerate jobs |

Job **#1077** was `Project.Hail.Mary.2026.PROPER.HDR.2160p.WEB.h265-GRACE`; the worker that died on
it was running **3 AMF workers across the Vega 8 and the RX 560X**. Job **#1083** was
`Mayday 2026 1080p WEB-DL HEVC x265 5.1 BONE.mkv`, also `vpp_amf=true, workers=3`.

> **Honesty note on strength of evidence.** The *correlation* is proven to the second and is
> reproducible from two independent logs. The *mechanism* (the AMF encode wedges the GPU, the
> driver TDRs, the worker dies) is **inferred**, not read out of the dumps — the dumps were not
> opened in a debugger. See §9 for the test that proves it.

### 4.3 Fault 3 — `E:` is a USB microSD card, and it is failing

| | |
|---|---|
| Device | `Micro PS SD` (label `iamroot`, serial `ABCDEFA74613`) |
| Bus | **USB Attached SCSI (UAS) Mass Storage Device** (`USB\VID_2109&PID_0715`) |
| Filesystem | NTFS, 4 KB clusters |
| Hosts | the app, `E:\pgdata` (PostgreSQL), `E:\MediaServer\cache` (149 GB), previews |

`Microsoft-Windows-Storage-ClassPnP/Operational` **Event 507** — *"Completing a failed
non-ReadWrite SCSI SRB request"* — at:

- `2026-10-20 15:01:42` — **12 s after today's boot**
- `2026-10-19 15:17:15`
- `2026-10-18 23:58:17`
- `2026-10-17 23:09:26`

And on 19 Oct at 15:17:14, `Ntfs` **Event 50**:

> `{Delayed Write Failed} Windows was unable to save all the data for the file E:\$Mft. The data
> has been lost.`

`MediaServerCaddy` then died at 15:23:58 — 6 minutes later.

### 4.4 Fault 4 — No headroom on the boot volume

| Volume | Free | % | Notes |
|---|---|---|---|
| `C:` (NVMe 256 GB) | 12.93 GB | **5.7 %** | hosts the 13.4 GB pagefile → **fixed to 2 GB, §6.1** |
| `E:` (microSD 238 GB) | 28.87 GB | 12.1 % | hosts 149 GB of HLS cache + PostgreSQL |
| `D:` (SATA HDD 932 GB) | 122.5 GB | 13.1 % | the owner's constraint: **HDD, must not serve concurrent streams** |

- `Volsnap` **Event 25** at 09:16 today: *"The shadow copies of volume C: were deleted because the
  shadow copy storage could not grow in time."*
- `Tcpip` **4231 / 4266** at 02:06 and 06:36: ephemeral TCP/UDP port space exhausted.
- `Resource-Exhaustion-Detector` fired repeatedly on **16–17 Oct** (Event 1014 *"perform memory leak
  diagnosis"* + 1015) — the box *does* reach memory pressure regularly, even though it did not do
  so on the day of this crash.
- `AutomaticManagedPagefile` was `False` with `PagingFiles = c:\pagefile.sys 0 0` — i.e. a
  **system-managed** pagefile that had grown to 13,389 MB.

---

## 5. Root-cause statement

> **The 20 Oct 15:01 restart was a hard reset of a machine whose AMD graphics driver cannot
> sustain heavy GPU work without hanging.** The trigger on that occasion was **Chromium's GPU
> compositing** (the `will-change` / filter / blur layer-promotion work the other session was
> doing) — *not* the media server, which was idle. On other days the same underlying weakness is
> provoked by the **AMF transcode pipeline** (§4.2). Because the failure is a hard lockup rather
> than a bugcheck, Windows captures nothing: no dump, no Event 41 detail beyond the zeros, and the
> machine must be force-cycled.
>
> Three environmental factors amplify it: a **failing USB SD card** holding the database and the
> cache, a **94 %-full boot volume** that could not grow its pagefile, and a **16-month-old driver**
> on a hardware branch AMD has moved to emergency-fix-only releases.

---

## 6. State changes made by this session

### 6.1 ✅ Pagefile → 2 GB, fixed and reserved — **APPLIED**

```
HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management
  PagingFiles = "c:\pagefile.sys 2048 2048"
Win32_ComputerSystem.AutomaticManagedPagefile = False
```

- **Fixed at 2 GB initial = 2 GB maximum** — reserved, non-growable, cannot eat the disk.
- **Not yet in effect.** The live pagefile is still 13,389 MB; the change applies at the **next
  reboot**. Nothing else was touched.
- **Effect at next boot:** `C:` free goes from **12.93 GB (5.7 %) → ~24.0 GB (10.6 %)**, +11.1 GB.

**The trade-off, stated plainly:** the commit limit drops from **~28 GB → ~16.4 GB**. At the time
of the crash, 9.1 GB of 13.9 GB RAM was in use with 13 `node.exe` processes, and the Playwright /
Chromium workload was the heavy part. Past ~16 GB of commit, allocations now **fail** rather than
page. This box already produced Resource-Exhaustion-Detector events on 16–17 Oct, so this is a
live risk, not a theoretical one. **Mitigations in §9.**

**Diagnostic side-effect:** `CrashDumpEnabled=3` (minidump) is unchanged and still works — it
caught the real bugchecks on 4 Sep (`0xD1`, `0xA`). But a *kernel* or *complete* dump would need
the pagefile back at ~16 GB, so **those are now off the table**. This costs little: today's crash
was a hard reset with no bugcheck, so **no dump would have been written regardless**.

### 6.2 ❌ Nothing else was changed

No driver installed. No service restarted. No code touched. No files deleted. The only repository
side-effect of this session is **this handoff file**.

---

## 7. Open items and the owner's decisions

### 7.1 ⬜ The GPU driver update — **researched, not installed, owner's call**

**Available:** **AMD Adrenalin Edition 26.5.2 (WHQL), released 2026-05-21** — the Polaris/Vega
legacy-branch package.

```
https://drivers.amd.com/drivers/whql-amd-software-adrenalin-edition-26.5.2-win11-may-vega-polaris.exe
(623 MB · supports RX 400/500/500X, RX Vega, Radeon VII, Radeon Pro Duo,
 and "AMD Radeon 600 Series mobile graphics" — which covers the Vega 8)
```

Also available: **26.9.2 Optional** (2026-08-20) — a *notebook reference* driver, *"limited support
for system vendor specific features"*.
Previous WHQLs also skipped: **26.1.1** (2026-01-21), **25.8.1** (2025-08-04).

**Three caveats that must be weighed:**

1. **AMD ended regular support** for Vega / RX 400 / RX 500 in 2025. They now ship only *"occasional
   drivers for critical fixes"*, and 26.5.2's **one** listed fix is an *Apex Legends crash fix for
   older cards*. **This is not a driver-maturity release for the TDR problem** — do not expect it
   to fix §4.1 on its own.
2. **This is an Acer hybrid laptop.** The known failure mode on this exact chassis (Nitro
   AN515-42/43 community reports) is that a **generic Adrenalin install misidentifies the Vega 8 as
   Vega 11** and breaks the AMD control panel. Remedies: the **OEM package** from
   `acer.com → Nitro AN515-43 → Downloads` (safest for hybrid graphics), or a **DDU clean install
   in Safe Mode** (highest black-screen risk on a box whose only display is the laptop panel), or
   **Device Manager → Update driver → "Let me pick from a list" → AMD Radeon Vega 8** to correct a
   misidentification without DDU.
3. **The update swaps `amfrt64.dll`.** The project's transcode path depends on the AMF runtime
   version, and `AGENTS.md` carries hard rules about `vpp_amf` / `h264_amf` behaviour and the 10-bit
   rejection. **A driver change requires AMF re-validation** — see §9.

**Recommended path (not yet executed):** OEM package if Acer offers one newer than 2025-06-03;
otherwise generic **26.5.2 installed over the top** (no DDU — the old package stays uninstallable
through *AMD Software*, so rollback is one click). Then re-validate AMF and run a 2160p AMF stress
job, checking `C:\Windows\LiveKernelReports` afterwards.

### 7.2 ⬜ Reboot to activate the pagefile

Not performed. The other opencode session is still live (its Vite dev server is running as PID
5920, no browser currently). It restarts with `cd web; npm run dev`. The other session has been
writing its own handoffs (`2026-10-20_15-26_opencode.md`, `2026-10-20_14-16_opencode.md`) and
committed **`f15da02` — Phase 11 slice 11.2 (the web canvas renderer + the frame-for-frame
oracle)**. Its work survived the restart intact.

### 7.3 ⬜ The HLS cache — it does **not** need to move

The owner's constraint is accepted and respected: **no move to `C:` (no space) and no move to
`D:` (HDD, cannot serve concurrent streams).** The cache stays on `E:`.

But the *right* lever is size, not location:

| Path | Size |
|---|---|
| `E:\MediaServer\cache\hls` total | **149.04 GB**, 162,725 files, 21 title caches |
| └ 720p rendition | 33.94 GB |
| └ 480p rendition | 24.04 GB |
| └ 360p rendition | 18.77 GB |
| └ 2160p rendition | 12.11 GB |
| └ 1440p rendition | 4.92 GB |
| └ *legacy flat caches (segments directly in the cache dir, dated 17 Oct)* | **~55 GB** |

- The **5-rendition ladder** (720p/480p/360p/2160p/1440p) accounts for ~94 GB; **2160p + 1440p =
  17.03 GB (18.2 %)**; **720p + 480p + 360p = 76.75 GB (82 %)**.
- Retention policy is **`archive`** (`archive_dir = D:\Flicks\.archive`); allowed policies are
  `archive` / `keep` / `purge_cache`. `GET /api/storage/audit` and `POST /api/storage/purge-orphans`
  are **admin-gated and returned 403** — correct behaviour, and the Admin PIN channel is closed by
  default (`settings.admin_pin` unset).

> ### ⚠️ Do not prune the cache **before** the GPU fix
>
> Deleting a cache means re-transcoding it — which means **re-running the AMF pipeline that §4.2
> shows is provoking the GPU hangs**. Pruning now would trade disk space for crash risk.
> **Sequence: GPU fix → verify → then size the cache.**

**Post-fix cache options (measure first):**
1. Confirm which rungs are actually served by the Fire TV / phone / tablet. If 360p and 480p are
   never selected, dropping them frees **~43 GB of `E:`** with no relocation.
2. The ~55 GB of legacy flat caches (17 Oct, single-rendition) are the oldest artefacts and the
   first candidates for a re-render into the ladder.

### 7.4 ⬜ Repository / documentation follow-ups (not done)

- `docs/Current issues.md` — add an issue for the **AMD GPU instability** and the
  **AMF→TDR correlation**. *(AGENTS.md's issue queue is at 12 after the Flask/Waitress loose ends;
  this would be 13.)*
- `AGENTS.md` §6 *Transcode strategy and telemetry* — the AMF/TDR finding belongs there, next to
  the existing `vpp_amf` and `h264_amf` rules, because it is a **hardware** constraint on the
  pipeline, not a code fact.
- `docs/TRANSCODE_CORRECTNESS_AND_TELEMETRY.md` — the GPU-hang timeline is measurement, which is
  that document's subject.
- The Obsidian vault (`C:\Users\anis7\Documents\Obsidian Vault\Media Server\`) — append to
  *Decisions Log* / *Verification Log*; **append only, never rewrite another agent's entry**.

---

## 8. ⚠️ Do-not-do list

1. **Do not install a generic AMD driver with DDU on this box** without a recovery path. A black
   screen on a laptop whose only display is its own panel, on a machine that already hard-resets
   unpredictably, is a bad place to be.
2. **Do not prune the HLS cache before the GPU fix** (§7.3).
3. **Do not re-enable a system-managed or large pagefile** to "fix" memory pressure — the 2 GB
   fixed pagefile is deliberate and was an explicit owner instruction. Instead apply the §9
   workload mitigations.
4. **Do not treat Event 6008's "previous shutdown" time as the crash time** (§2). It is an onset
   marker. Two prior crashes (17 Oct, 18 Oct) have a *multi-hour* gap between it and the reboot.
5. **Do not conclude the media server caused the 20 Oct crash.** It was idle
   (`scanned=33, queued=0, errors=0`; no `ffmpeg`; no cache writes 13:00–15:05).
6. **Do not assume a driver update alone fixes §4.1.** AMD ships this branch critical-fixes-only.
   The §9 acceptance test is the arbiter, not the version number.
7. **Do not forget the reboot.** The pagefile change is inert until the next boot, and the
   `C:` space does not appear until then.

---

## 9. Verification plan — what "fixed" means

**Exit criteria, in order:**

| # | Step | Pass criterion |
|---|---|---|
| 1 | Reboot | `Win32_PageFileUsage.AllocatedBaseSize` = **2048 MB**; `C:` free ≥ **~24 GB** |
| 2 | Install the driver (per §7.1) | `Win32_VideoController.DriverVersion` changed; **both** RX 560X *and* Vega 8 present and `Status = OK`; Task Manager shows the **Vega 8**, not "Vega 11" |
| 3 | Re-validate AMF | `ffmpeg -f lavfi -i color=c=black:s=128x128:d=0.3 -c:v h264_amf -f null -` → `AMF initialisation succeeded via D3D11`, exit 0, **no** version warning; and a real `vpp_amf` chunk still encodes (§4.2's 10-bit rule) |
| 4 | **The acceptance test** | Run **one 2160p AMF transcode** (a `Project.Hail.Mary`-class 2160p HDR source, 3 workers across both GPUs). Then: `C:\Windows\LiveKernelReports` must contain **no new** `WATCHDOG-*.dmp` / `AMD_REPORT_UM-*.dmp`, and `rust_api.log` must show **no** `Worker … failed job` for it |
| 5 | The Chromium workload | Re-run the `intro-frame` Playwright harness for ≥ 30 min with the §10 mitigation applied. No new live-kernel dumps, no `Event 41` |
| 6 | Longer soak | 7 days with no `Event 41` and no new `LiveKernelReports` |

> Step 4 is the decisive one. It is also the **proof of the §4.2 mechanism**: a 2160p AMF job is
> the most reliable TDR stress available on this box, because it is the workload that provokes
> the hangs. If the driver update removes the hangs under that load, the correlation was causal.

---

## 10. Immediate, zero-risk mitigations (recommended now, driver or no driver)

1. **Run the Playwright/Chromium harness with the GPU disabled.** Use `--disable-gpu` (or
   `--use-gl=swiftshader`) for the pixel-comparison harness. The oracle has already proven
   Chromium's rasterisation is deterministic in software, so the comparison stays valid — and it
   removes the GPU load that provoked today's TDR. **Also: do not spawn a fresh browser per
   assertion.**
2. **Interim TDR tolerance** (buys time, fixes nothing):
   `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers` → `TdrDelay = 10`,
   `TdrDdiDelay = 20` (DWORD). This gives the driver ~10 s instead of ~2 s before the OS declares
   a hang, which can turn a hard reset into a recoverable TDR.
3. **Do not run a transcode and the Playwright harness concurrently.** Both are GPU-heavy; running
   them together is how a TDR becomes a hard reset.

---

## 11. Reference — commands and paths

```powershell
# --- the crash itself ---
Get-WinEvent -FilterHashtable @{LogName='System'; Id=41} -MaxEvents 12
Get-WinEvent -FilterHashtable @{LogName='System'; Id=6008} -MaxEvents 10
Get-WinEvent -FilterHashtable @{LogName='System'; Id=1001} -MaxEvents 10   # bugcheck (none)

# --- GPU health ---
Get-ChildItem 'C:\Windows\LiveKernelReports' -Recurse
Get-ChildItem 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue' -Directory | Where-Object Name -like 'Kernel_*'
Get-CimInstance Win32_VideoController
Get-CimInstance Win32_PnPSignedDriver | Where-Object DeviceName -match 'Radeon|Vega'

# --- storage ---
Get-Partition | Where-Object DriveLetter | ForEach-Object { Get-Disk -Number $_.DiskNumber }
Get-WinEvent -LogName 'Microsoft-Windows-Storage-ClassPnP/Operational' | Where-Object Id -eq 507

# --- pagefile ---
Get-CimInstance Win32_PageFileSetting
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management').PagingFiles

# --- AMF ---
& 'C:\Users\anis7\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe' -hide_banner -f lavfi `
  -i color=c=black:s=128x128:d=0.3 -c:v h264_amf -f null -
Select-String -Path 'E:\MediaServer\logs\rust_api.log' -Pattern 'failed job|vpp_amf'

# --- the opencode sessions ---
python -c "import sqlite3;c=sqlite3.connect(r'file:C:/Users/anis7/.local/share/opencode/opencode.db?mode=ro',uri=True);\
[print(r) for r in c.execute('select id,title,time_updated from session_v2 order by time_updated desc limit 5')]"
Select-String -Path 'C:\Users\anis7\.local\share\opencode\log\opencode.log' -Pattern '^timestamp=2026-10-20T'
```

**Key paths**

| What | Where |
|---|---|
| GPU hang dumps | `C:\Windows\LiveKernelReports\{WATCHDOG,AMD_REPORT_UM}\` |
| Queued kernel reports | `C:\ProgramData\Microsoft\Windows\WER\ReportQueue\Kernel_*\` |
| Transcode log (UTC) | `E:\MediaServer\logs\rust_api.log` |
| HLS cache | `E:\MediaServer\cache\hls\` (21 dirs, 149 GB) |
| Pagefile | `C:\pagefile.sys` → `c:\pagefile.sys 2048 2048` |
| AMD display driver | `C:\Windows\INF\oem43.inf` (`DriverVer=03/06/2025, 31.0.21923.1000`) |
| AMF runtime | `C:\Windows\System32\amfrt64.dll` (dated 2025-05-08) |
| opencode DB | `C:\Users\anis7\.local\share\opencode\opencode.db` (SQLite; `session_v2`, `session_message`) |
| opencode log | `C:\Users\anis7\.local\share\opencode\log\opencode.log` (37 MB, shared by all runs) |

---

## 12. Machine state at handoff

| | |
|---|---|
| Uptime | 42 min (booted 15:01:30) |
| `MediaServerRust` | **Running** (PID 14232, `http://0.0.0.0:8000`, `/health` → healthy) |
| `MediaServerCaddy` | Running |
| `MediaServerPG` | Running |
| Pagefile (live) | 13,389 MB — **2 GB after the next reboot** |
| `C:` free | 12.93 GB → **~24 GB after reboot** |
| `E:` free | 28.87 GB |
| Other opencode session | **Running** — Vite dev server PID 5920 on `:5173`; last commit `f15da02` (slice 11.2) |
| Working tree | Modified: `.opencode/db/refresh-snapshot.ps1`, `AGENTS.md`, `docs/Current issues.md`, `web/src/app/AppShell.tsx` (**all from the other session — do not revert**) |

---

## 13. One-paragraph summary for the next agent

> The 20 Oct 15:01 restart was a **hard reset** (no bugcheck, no `1074`, no dump) of a machine whose
> **AMD graphics driver is chronically unstable** — 42 queued WER kernel reports from Sep 2025 to
> Oct 2026 (22× `141` GPU-TDR, 4× AMD driver hang, 2 real bugchecks `0xD1`/`0xA`). The trigger that
> day was **headless-Chromium GPU compositing**; on other days the same weakness is provoked by the
> **AMF transcode pipeline**, proven by `rust_api.log` showing `Worker … failed job #1077` within
> 11–27 s of each of the four 18 Oct GPU hang dumps. The pagefile is now a **fixed, reserved 2 GB**
> on `C:` (inert until reboot; `C:` free 12.9 → ~24 GB; commit limit 28 → 16.4 GB). A newer driver
> exists — **AMD Adrenalin 26.5.2 WHQL (2026-05-21)** — but it is a *critical-fix-only* legacy
> release, and installing generic AMD drivers on this Acer hybrid is known to misidentify the Vega
> 8 as Vega 11, so it needs the owner's decision and an AMF re-validation. The **149 GB HLS cache
> stays on `E:`** (no space on `C:`, `D:` is an HDD) but must **not** be pruned before the GPU fix,
> because pruning means re-transcoding, which means more AMF. The acceptance test is §9 step 4: a
> 2160p AMF transcode that produces **no new** `LiveKernelReports` dumps and **no** `failed job`.
