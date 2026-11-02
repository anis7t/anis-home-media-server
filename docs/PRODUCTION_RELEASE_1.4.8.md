# Production Release 1.4.8

**Released:** 2026-11-03 (Asia/Calcutta)

**Targets:** Rust/Axum server, React web app, universal Android/TV APK

**Status:** Deployed and live

## Android/TV artifact

- Package: `in.anisparvez.media_server_client`
- Version: `1.4.8` (versionCode `154`)
- Minimum SDK: 24; target SDK: 36
- SHA-256: `63af9814a082e7fb5f9a59de179dd8fc2f3d00bd96ac862adec7d8518d178e2f`
- Production endpoint: `/api/app/update?channel=production`
- APK endpoint: `/api/app/download?channel=production`

The published manifest reported the same package, version, SDK levels, and hash as the APK downloaded from the production endpoint. The downloaded APK was installed on the connected Android phone.

## Changes

- Android playback progress now posts through the authenticated API client with the persistent device identity. The server returns account-scoped Continue Watching items ordered by their latest saved progress.
- The Android home feed and React web library now include Recently Added, ordered by catalog upload time. Existing catalog entries without `added_at` are backfilled from file modification time.
- The scanner excludes HLS initialization assets (`init.mp4`, `init_chunk_<n>.mp4`, and legacy `init_*.mp4` fixtures). The movie API filters stale catalog entries immediately; the production scan pruned nine fixture rows while leaving the media files untouched.
- The release includes the current Android HLS seek, resume, timeline, and quality-switching changes from the release worktree.

## Production verification

- Rust service restarted on the production host; local and public `/health` returned 200.
- Public `/api/movies` returned no `init_*` titles. The cleanup scan reported nine pruned catalog rows and zero errors; the nine source files remained on disk.
- The public web app showed Recently Added in upload-time order. After a cold launch, the Android app showed the cleaned 36-title catalog and the corresponding Recently Added order.
- Playing *Verity* on the phone updated its account progress. It became the first Continue Watching card in the phone app and web library.
- Regression checks: Rust HLS integration suite, including init cleanup (19 passed); Continue Watching ordering (1 passed); Flutter progress/auth (7 passed); Flutter HLS seek/resume (5 passed); web library (12 passed).

## Rollback and provenance

The previous APK, production manifest, version registry, Rust executable, and web bundle are backed up under `backups/prod-release-2026-11-03_004746/`.

The production APK manifest records `gitCommit: ba6f980`, which was HEAD when the artifact was published. The deployed artifacts also included the working-tree changes documented here; the following source commit records them after deployment.
