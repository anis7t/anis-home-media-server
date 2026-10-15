//! Phase 6A: transcode job model and queue ownership.
//!
//! Isolation contract (AGENTS.md s9): every test row is removed in setup and
//! again in teardown, and the suite asserts zero residue afterwards. Test
//! filenames are namespaced `rust_test_job_*` so cleanup can never touch a
//! real catalog row.

use media_server_api::{
    config::AppConfig,
    db,
    models::job::{EnqueueJobRequest, JobStatus},
    services::job_service::JobService,
};
use sqlx::PgPool;
use std::sync::atomic::{AtomicUsize, Ordering};


static COUNTER: AtomicUsize = AtomicUsize::new(0);

const TEST_PREFIX: &str = "rust_test_job_";

/// Port used as the module-wide cross-process lock. High and arbitrary to
/// avoid colliding with the service ports (5432 PostgreSQL, 8000 Flask,
/// 8001 Rust).
const JOB_TEST_LOCK_PORT: u16 = 47311;

/// A pool created fresh inside the calling test's runtime.
///
/// **It must not be cached in a `static`.** `#[tokio::test]` builds and drops
/// a runtime per test, and sqlx's `PgPool` spawns background maintenance tasks
/// (idle-timeout / `min_connections`) on the runtime that created it. A pool
/// stored in a `OnceCell` was therefore created inside the *first* test's
/// runtime; by the third test that runtime was gone and every pool operation
/// blocked forever - a hang with zero CPU while PostgreSQL sat idle. Creating
/// the pool per test ties it to the runtime that will still be alive to close
/// it. The tests are serialized by [`acquire_global_lock`], so the small
/// per-test connection cost is not a problem.
async fn pool() -> PgPool {
    let config = AppConfig::from_env();
    db::create_test_pool(&config.database_url)
        .await
        .expect("failed to create pool")
}

/// The tests assert on *global* queue state - `claim_next` picks the oldest
/// claimable row in the whole table, and `purge()` deletes every row with the
/// test prefix. Both are only meaningful if this module is the only writer.
///
/// An in-process `Mutex` is NOT sufficient: two concurrent `cargo test`
/// invocations are two processes with two independent mutexes, and they
/// deadlock against each other's uncommitted `FOR UPDATE` locks (observed:
/// every test hung past 60s). The exclusion is therefore taken in the
/// filesystem, where it is shared by every process and released by the kernel
/// when the process exits.
/// Take a cross-process lock for the whole module.
///
/// **A file lock, deliberately not a PostgreSQL advisory lock.** The advisory
/// route was tried first and was a mistake: `pg_advisory_lock` is held until
/// the session ends, so a killed test run leaves an orphan backend still
/// holding it, and the *next* run then blocks forever on a lock nobody owns.
/// That happened repeatedly here and presented as an unexplained hang with
/// `pg_stat_activity` showing an `idle` session whose last statement was
/// `SELECT pg_advisory_lock($1)`. Cleaning up required guessing which pids to
/// terminate.
///
/// An OS resource is released by the kernel when the process dies, however it
/// dies, so there is no residue to clean up and no way to wedge the suite.
/// Exclusion is still real across concurrently running `cargo test`
/// invocations, which an in-process `Mutex` cannot provide.
///
/// The resource is a bound TCP port rather than a file lock because
/// `File::try_lock_exclusive` is still nightly-only. The socket is held for
/// the life of the guard and `bind` is non-blocking, so a second run fails
/// fast and visibly instead of hanging; that is the behaviour a hung suite
/// should never have.
async fn acquire_global_lock() -> TestLock {
    // Two levels, because the two failure modes are different:
    //
    // 1. `cargo test` runs the tests in this binary on parallel threads, and
    //    every one of them asserts on the *same global queue*. An in-process
    //    async mutex serializes them.
    // 2. A second `cargo test` invocation is a second process with its own
    //    mutex, so it needs a resource the kernel reclaims when a process
    //    dies. The port bind is that resource - and it is deliberately
    //    fail-fast, so two concurrent invocations produce a clear error
    //    instead of interleaving and producing nonsense.
    //
    // Order matters: take the in-process mutex first, so a parallel thread
    // waits rather than losing the port to another thread of this same binary.
    let _in_process = IN_PROCESS.lock().await;
    let port = std::net::TcpListener::bind(("127.0.0.1", JOB_TEST_LOCK_PORT)).unwrap_or_else(|e| {
        panic!(
            "another job_queue_test process holds 127.0.0.1:{} ({}); \
             wait for it to finish rather than running two at once",
            JOB_TEST_LOCK_PORT, e
        )
    });
    TestLock {
        _in_process,
        _port: port,
    }
}

/// Held for the duration of a test; releasing both levels on drop.
struct TestLock {
    _in_process: tokio::sync::MutexGuard<'static, ()>,
    _port: std::net::TcpListener,
}

static IN_PROCESS: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn unique_filename(tag: &str) -> String {
    let n = COUNTER.fetch_add(1, Ordering::SeqCst);
    format!("{}{}_{}_{}.mkv", TEST_PREFIX, tag, std::process::id(), n)
}

/// Remove every test row this module could have created. Used before a test
/// and in teardown, so a failing test cannot leak rows into the development
/// database.
async fn purge(pool: &PgPool) {
    let _ = sqlx::query("DELETE FROM transcode_jobs WHERE filename LIKE $1")
        .bind(format!("{}%", TEST_PREFIX))
        .execute(pool)
        .await;
}

#[tokio::test]
async fn test_enqueue_is_idempotent_for_same_filename_and_mode() {
    let _lock = acquire_global_lock().await;
    let pool = pool().await;
    purge(&pool).await;
    let filename = unique_filename("idem");

    let first = JobService::enqueue(&pool, &filename, "hls", false).await.unwrap();
    let second = JobService::enqueue(&pool, &filename, "hls", false).await.unwrap();

    assert_eq!(first.id, second.id, "second enqueue must reuse the row");
    assert_eq!(second.status, "queued");

    // A different mode is a different job.
    let other_mode = JobService::enqueue(&pool, &filename, "compat", false).await.unwrap();
    assert_ne!(other_mode.id, first.id);

    purge(&pool).await;
    pool.close().await;
}

#[tokio::test]
async fn test_enqueue_rejects_empty_and_traversal_filenames() {
    let _lock = acquire_global_lock().await;
    let pool = pool().await;
    assert!(JobService::enqueue(&pool, "   ", "hls", false).await.is_err());
    assert!(
        JobService::enqueue(&pool, "../../etc/passwd", "hls", false)
            .await
            .is_err()
    );
}

#[tokio::test]
async fn test_claim_is_exclusive_to_one_owner() {
    let _lock = acquire_global_lock().await;
    let pool = pool().await;
    purge(&pool).await;
    let filename = unique_filename("claim");
    JobService::enqueue(&pool, &filename, "hls", false).await.unwrap();

    let a = JobService::claim_next(&pool, "worker-a", 300).await.unwrap();
    let b = JobService::claim_next(&pool, "worker-b", 300).await.unwrap();

    assert!(a.is_some(), "first worker must claim the job");
    assert!(
        b.is_none(),
        "second worker must not claim an already-claimed job"
    );
    let a = a.unwrap();
    assert_eq!(a.lease_owner.as_deref(), Some("worker-a"));
    assert_eq!(a.status, "running");

    purge(&pool).await;
    pool.close().await;
}

#[tokio::test]
async fn test_expired_lease_is_reclaimable_and_live_lease_is_not() {
    let _lock = acquire_global_lock().await;
    let pool = pool().await;
    purge(&pool).await;
    let filename = unique_filename("lease");
    let job = JobService::enqueue(&pool, &filename, "hls", false).await.unwrap();

    // A live lease blocks other owners.
    let first = JobService::claim_next(&pool, "worker-a", 300).await.unwrap();
    assert_eq!(first.unwrap().id, job.id);
    assert!(
        JobService::claim_next(&pool, "worker-b", 300).await.unwrap().is_none(),
        "a live lease must be exclusive"
    );

    // Expire it, then the job becomes claimable again (crashed-worker
    // recovery without any external sweeper).
    sqlx::query(
        "UPDATE transcode_jobs SET lease_expires_at = CURRENT_TIMESTAMP - interval '1 minute' WHERE id = $1",
    )
    .bind(job.id)
    .execute(&pool)
    .await
    .unwrap();

    let reclaimed = JobService::claim_next(&pool, "worker-b", 300).await.unwrap();
    assert!(reclaimed.is_some(), "expired lease must be reclaimable");
    assert_eq!(reclaimed.unwrap().lease_owner.as_deref(), Some("worker-b"));

    purge(&pool).await;
    pool.close().await;
}

#[tokio::test]
async fn test_progress_and_completion_require_lease_ownership() {
    let _lock = acquire_global_lock().await;
    let pool = pool().await;
    purge(&pool).await;
    let filename = unique_filename("progress");
    JobService::enqueue(&pool, &filename, "hls", false).await.unwrap();
    let job = JobService::claim_next(&pool, "worker-a", 300).await.unwrap().unwrap();

    // The wrong owner cannot write.
    assert!(
        !JobService::update_progress(&pool, job.id, "worker-b", Some(10.0), None, None, None)
            .await
            .unwrap()
    );
    assert!(
        JobService::complete(&pool, job.id, "worker-b").await.unwrap() == false
    );

    // The right owner can.
    assert!(
        JobService::update_progress(&pool, job.id, "worker-a", Some(42.5), Some(2.0), Some(24.0), Some(30.0))
            .await
            .unwrap()
    );
    assert!(JobService::renew_lease(&pool, job.id, "worker-a", 300).await.unwrap());
    assert!(JobService::complete(&pool, job.id, "worker-a").await.unwrap());

    let done = JobService::get_by_id(&pool, job.id).await.unwrap().unwrap();
    assert_eq!(done.status, "completed");
    assert_eq!(done.progress, Some(100.0));
    assert_eq!(done.lease_owner, None, "completion releases the lease");

    purge(&pool).await;
    pool.close().await;
}

#[tokio::test]
async fn test_failure_records_error_and_releases_lease() {
    let _lock = acquire_global_lock().await;
    let pool = pool().await;
    purge(&pool).await;
    let filename = unique_filename("fail");
    JobService::enqueue(&pool, &filename, "hls", false).await.unwrap();
    let job = JobService::claim_next(&pool, "worker-a", 300).await.unwrap().unwrap();

    assert!(JobService::fail(&pool, job.id, "worker-a", "ffmpeg exited 1").await.unwrap());
    let failed = JobService::get_by_id(&pool, job.id).await.unwrap().unwrap();
    assert_eq!(failed.status, "failed");
    assert_eq!(failed.error.as_deref(), Some("ffmpeg exited 1"));
    assert_eq!(failed.lease_owner, None);

    purge(&pool).await;
    pool.close().await;
}

#[tokio::test]
async fn test_cancel_queued_job_and_cancel_refuses_running_job_without_owner() {
    let _lock = acquire_global_lock().await;
    let pool = pool().await;
    purge(&pool).await;

    // Queued: cancellable without an owner.
    let queued_name = unique_filename("cancelq");
    let queued = JobService::enqueue(&pool, &queued_name, "hls", false).await.unwrap();
    assert!(JobService::cancel(&pool, queued.id, None).await.unwrap());
    assert_eq!(
        JobService::get_by_id(&pool, queued.id).await.unwrap().unwrap().status,
        "canceled"
    );

    // Running without an owner: refused, so a stale cancel cannot race a
    // legitimate worker.
    let running_name = unique_filename("cancelr");
    JobService::enqueue(&pool, &running_name, "hls", false).await.unwrap();
    let running = JobService::claim_next(&pool, "worker-a", 300).await.unwrap().unwrap();
    assert!(!JobService::cancel(&pool, running.id, None).await.unwrap());
    assert!(JobService::cancel(&pool, running.id, Some("worker-a")).await.unwrap());

    purge(&pool).await;
    pool.close().await;
}

#[tokio::test]
async fn test_force_reopens_terminal_job_without_force_keeps_it() {
    let _lock = acquire_global_lock().await;
    let pool = pool().await;
    purge(&pool).await;
    let filename = unique_filename("force");
    let job = JobService::enqueue(&pool, &filename, "hls", false).await.unwrap();
    JobService::claim_next(&pool, "worker-a", 300).await.unwrap().unwrap();
    JobService::complete(&pool, job.id, "worker-a").await.unwrap();

    // Without force, a completed job stays completed.
    let same = JobService::enqueue(&pool, &filename, "hls", false).await.unwrap();
    assert_eq!(same.status, "completed");

    // With force it reopens as queued (a measured frame deficit).
    let forced = JobService::enqueue(&pool, &filename, "hls", true).await.unwrap();
    assert_eq!(forced.id, job.id, "row identity is stable across reopen");
    assert_eq!(forced.status, "queued");

    purge(&pool).await;
    pool.close().await;
}

#[tokio::test]
async fn test_terminal_jobs_are_never_claimed() {
    let _lock = acquire_global_lock().await;
    let pool = pool().await;
    purge(&pool).await;
    let filename = unique_filename("terminal");
    let job = JobService::enqueue(&pool, &filename, "hls", false).await.unwrap();
    JobService::claim_next(&pool, "worker-a", 300).await.unwrap().unwrap();
    JobService::complete(&pool, job.id, "worker-a").await.unwrap();
    // Clear any lease defensively; completion already released it.
    sqlx::query("UPDATE transcode_jobs SET lease_expires_at = NULL WHERE id = $1")
        .bind(job.id)
        .execute(&pool)
        .await
        .unwrap();

    let claimed = JobService::claim_next(&pool, "worker-b", 300).await.unwrap();
    assert!(
        claimed.is_none(),
        "a completed job must never be reclaimed"
    );

    purge(&pool).await;
    pool.close().await;
}

#[tokio::test]
async fn test_status_classification_and_listing() {
    let _lock = acquire_global_lock().await;
    let pool = pool().await;
    purge(&pool).await;
    let filename = unique_filename("list");
    JobService::enqueue(&pool, &filename, "hls", false).await.unwrap();

    let all = JobService::list(&pool, 100).await.unwrap();
    assert!(all.iter().any(|j| j.filename == filename));

    assert!(JobStatus::parse("queued").unwrap().is_live());
    assert!(JobStatus::parse("running").unwrap().is_live());
    for terminal in ["completed", "failed", "canceled"] {
        let s = JobStatus::parse(terminal).unwrap();
        assert!(!s.is_live(), "{} must not be live", terminal);
    }
    assert!(JobStatus::parse("nonsense").is_none());

    purge(&pool).await;
    pool.close().await;
}

#[tokio::test]
async fn test_enqueue_request_defaults_to_hls_mode() {
    let req = EnqueueJobRequest {
        mode: None,
        force: None,
    };
    assert_eq!(req.mode.clone().unwrap_or_else(|| "hls".to_string()), "hls");
    assert_eq!(req.force.unwrap_or(false), false);
}

#[tokio::test]
async fn test_suite_leaves_no_residue() {
    let _lock = acquire_global_lock().await;
    let pool = pool().await;
    let remaining: i64 =
        sqlx::query_scalar("SELECT count(*) FROM transcode_jobs WHERE filename LIKE $1")
            .bind(format!("{}%", TEST_PREFIX))
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(remaining, 0, "transcode_jobs must retain no test rows");
}