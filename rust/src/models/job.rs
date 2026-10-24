use serde::{Deserialize, Serialize};

/// Lifecycle of a transcode job. `idle` is never stored: it is derived by
/// the status endpoint when no row exists (or when a row was cleaned up).
///
/// The terminal states are `completed`, `failed` and `canceled`. Only
/// `queued` and `running` are live, and only those two are ever claimed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum JobStatus {
    Queued,
    Running,
    Completed,
    Failed,
    Canceled,
}

impl JobStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            JobStatus::Queued => "queued",
            JobStatus::Running => "running",
            JobStatus::Completed => "completed",
            JobStatus::Failed => "failed",
            JobStatus::Canceled => "canceled",
        }
    }

    pub fn parse(s: &str) -> Option<JobStatus> {
        match s {
            "queued" => Some(JobStatus::Queued),
            "running" => Some(JobStatus::Running),
            "completed" => Some(JobStatus::Completed),
            "failed" => Some(JobStatus::Failed),
            "canceled" => Some(JobStatus::Canceled),
            _ => None,
        }
    }

    /// A live job is one a scheduler may still act on. Terminal jobs are
    /// never reclaimed, and `completed` is never re-claimed because the
    /// only writer that sets it has, by definition, finished the work.
    pub fn is_live(&self) -> bool {
        matches!(self, JobStatus::Queued | JobStatus::Running)
    }
}

/// One transcode job as persisted in `transcode_jobs`.
///
/// `lease_owner` + `lease_expires_at` are the ownership primitive: a
/// scheduler claims a row by writing its identity and a deadline inside a
/// single conditional UPDATE, so two schedulers can never both hold the
/// same job. A `running` row whose lease has expired is reclaimable - that
/// is how a crashed worker's job is recovered after a restart.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranscodeJob {
    pub id: i64,
    pub filename: String,
    pub mode: String,
    pub status: String,
    pub progress: Option<f64>,
    pub speed: Option<f64>,
    pub fps: Option<f64>,
    pub eta: Option<f64>,
    pub resume_time: Option<f64>,
    pub start_seg: Option<i32>,
    pub attempts: i32,
    pub priority: i32,
    pub error: Option<String>,
    pub lease_owner: Option<String>,
    pub lease_expires_at: Option<chrono::DateTime<chrono::Utc>>,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct EnqueueJobRequest {
    #[serde(default)]
    pub mode: Option<String>,
    /// `force` mirrors Flask's `ensure_hls_transcode(force=True)`: it skips
    /// the completeness gate and exists ONLY for a measured frame deficit.
    #[serde(default)]
    pub force: Option<bool>,
    /// Priority level: 0 for background, 10 for interactive user requests.
    #[serde(default)]
    pub priority: Option<i32>,
}