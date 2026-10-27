pub mod acceptance;
pub mod auth;
pub mod cli;
pub mod client;
pub mod credential_file;
pub mod credentials;
pub mod extractor;
pub mod media;
pub mod pagination;
pub mod signing;
pub mod storage;
pub mod transport;
pub mod verify;

pub const MAX_MEDIA_BYTES: u64 = 104_857_600;
pub const BUFFER_BYTES: usize = 64 * 1024;
pub type Result<T> = std::result::Result<T, Error>;

// Fixture builds can assert that the diagnostic command never enters active operations.
// A violation stops before signing, DNS resolution, or client construction.
#[cfg(feature = "offline-test")]
pub fn assert_active_operations_allowed() {
    assert!(
        std::env::var_os("DOUSTUDIO_TEST_FORBID_ACTIVE_OPERATIONS").is_none(),
        "OFFLINE_DIAGNOSTIC_BOUNDARY_VIOLATION"
    );
}

// Deliberately fixed messages: never attach a URL, HTTP body, credential or child stderr.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum Error {
    #[error("ACCEPTANCE_STOPPED_SEE_SANITIZED_DIAGNOSTICS")]
    Acceptance,
    #[error("AUTHORIZATION_REQUIRED")]
    Authorization,
    #[error("CREDENTIAL_INVALID_OR_MISSING")]
    Credential,
    #[error("COOKIE_FILE_REJECTED_OR_UNREADABLE")]
    CredentialFile,
    #[error("PROFILE_OR_SIGNED_REQUEST_SCOPE_INVALID")]
    Scope,
    #[error("PRODUCTION_MEDIA_ALLOWLIST_EMPTY")]
    ProductionDenied,
    #[error("TEST_SCOPE_INVALID_OR_EXPIRED")]
    TestScope,
    #[error("NETWORK_TARGET_REJECTED")]
    NetworkTarget,
    #[error("NETWORK_OR_TLS_ERROR")]
    Network,
    #[error("ACCESS_RESTRICTED_OR_SESSION_EXPIRED")]
    Access,
    #[error("RATE_LIMITED")]
    RateLimited,
    #[error("CHALLENGE_OR_NON_JSON_RESPONSE")]
    Challenge,
    #[error("RESPONSE_SCHEMA_INVALID")]
    Schema,
    #[error("PAGINATION_STALLED_OR_CYCLIC")]
    Cursor,
    #[error("REDIRECT_REJECTED")]
    Redirect,
    #[error("MEDIA_HEADERS_OR_STATUS_REJECTED")]
    Headers,
    #[error("APPLICATION_BYTE_BUDGET_EXCEEDED")]
    Budget,
    #[error("DECLARED_LENGTH_MISMATCH")]
    Length,
    #[error("CANCELLED")]
    Cancelled,
    #[error("IO_OR_OUTPUT_PATH_ERROR")]
    Io,
    #[error("OUTPUT_ALREADY_EXISTS")]
    Exists,
    #[error("MEDIA_CONTAINER_INVALID")]
    Container,
    #[error("MEDIA_PROBE_OR_FULL_DECODE_FAILED")]
    Decode,
    #[error("FFMPEG_OR_FFPROBE_UNAVAILABLE")]
    VerifierMissing,
    #[error("DEADLINE_EXCEEDED")]
    Timeout,
    #[error("UNSUPPORTED_WORK_OR_INDEX")]
    Selection,
}
