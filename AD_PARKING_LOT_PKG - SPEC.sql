create or replace PACKAGE AD_PARKING_LOT_PKG AS

    /*
    || AD_PARKING_LOT_PKG
    || ─────────────────────────────────────────────────────────────────────
    || Single entry point: DISPATCH (no parameters)
    ||
    ||   Loads all active OIC environments and calls the OIC monitoring
    ||   API ONCE per environment.  Discovers all interfaces with
    ||   QUEUED/RETRY messages and routes each one based on DISPATCH_TYPE:
    ||
    ||   ATP_INDIVIDUAL → one OIC instance per message
    ||                    chunks of max 50, one scheduler job per chunk
    ||
    ||   ATP_GROUP      → one OIC instance per (MSG_SEQUENCE, INTERFACE_ID)
    ||                    one scheduler job per group
    ||                    all msgs in the group share the same CHUNK_ID
    ||
    ||   OIC environment quota pool is shared across all interfaces in
    ||   the same run.  High-priority interfaces consume first.
    || ─────────────────────────────────────────────────────────────────────
    */

    -- ── Error logger ──────────────────────────────────────────────────────────
    -- Writes a row to AD_ATP_ERRORS via an autonomous transaction.
    -- Safe to call from any package or procedure — never raises.
    -- Pass SQLCODE and SQLERRM explicitly from inside the WHEN OTHERS block
    -- to guarantee the correct error context is captured.
    PROCEDURE P_LOG_ERROR
    (
        p_procedure_name IN VARCHAR2,
        p_error_code     IN NUMBER    DEFAULT NULL,
        p_error_message  IN VARCHAR2  DEFAULT NULL,
        p_interface_id   IN VARCHAR2  DEFAULT NULL,
        p_stage_number   IN NUMBER    DEFAULT NULL,
        p_msg_id         IN NUMBER    DEFAULT NULL,
        p_msg_sequence   IN NUMBER    DEFAULT NULL,
        p_notes          IN VARCHAR2  DEFAULT NULL
    );

    -- ── OAuth / environment credentials ───────────────────────────────────────
    -- Stores encrypted OAuth2 client credentials for an OIC environment.
    -- CLIENT_SECRET is encrypted with AES256 before being written to the table.
    -- Call this instead of UPDATE ... SET CLIENT_SECRET = plain_text directly.
    PROCEDURE SET_ENV_CREDENTIALS
    (
        p_env_id        IN AD_OIC_ENVIRONMENTS.ENV_ID%TYPE,
        p_client_id     IN VARCHAR2,
        p_client_secret IN VARCHAR2
    );

    -- Sequences QUEUED/RETRY msgs to READY_TO_DISPATCH before dispatching
    -- Test helper: returns a fresh Bearer token for the given env
    -- Use only for testing — do not call in production flows
    FUNCTION GET_TOKEN_FOR_TEST
    (
        p_env_id IN AD_OIC_ENVIRONMENTS.ENV_ID%TYPE
    ) RETURN VARCHAR2;

    PROCEDURE SEQUENCE_MSGS;

    -- Single entry point — called by scheduler or manually
    PROCEDURE DISPATCH;

    -- Called by DBMS_SCHEDULER job (one per env) to fetch live running
    -- instance count from OIC and write to AD_OIC_ENVIRONMENTS.LAST_RUNNING_COUNT.
    -- Must be public so the scheduler job action can invoke it.
    PROCEDURE GET_RUNNING_INSTANCES
    (
        p_env_id IN AD_OIC_ENVIRONMENTS.ENV_ID%TYPE
    );

    -- Called by each scheduler job for individual dispatch
    PROCEDURE DISPATCH_INDIVIDUAL_CHUNK
    (
        p_chunk_id IN VARCHAR2
    );

    -- Called by each scheduler job for group dispatch
    PROCEDURE DISPATCH_GROUP_CHUNK
    (
        p_chunk_id IN VARCHAR2
    );

    -- Standalone BIP dispatcher — called from its own scheduler
    PROCEDURE DISPATCH_BIP;

    -- Called by each scheduler job spawned by DISPATCH_BIP
    PROCEDURE DISPATCH_BIP_CHUNK
    (
        p_chunk_id IN VARCHAR2
    );

    -- ── Group dispatcher / archiving / retry ─────────────────────────────────
    -- Retries ERROR msgs where RETRY_ENABLED = 'Y' and RETRY_CONDITION is met
    PROCEDURE RETRY_FAILED_MSGS;

    -- Archives processed/stale msgs+files, purges old archives, gathers stats
    PROCEDURE ARCHIVE_COLLECT_STATS;

    -- Fetches eligible group-dispatch records into AD_GROUP_DISPATCHER_READY_GT
    -- and returns them as an AD_GROUP_DISPATCHER_TYPE collection
    PROCEDURE FETCH_GROUP_DISPATCHER_RECORDS
    (
        p_limit                          IN  NUMBER,
        p_dispatcher_integration_code    IN  VARCHAR2,
        p_dispatcher_integration_instance IN  VARCHAR2,
        x_fetch_status                   OUT VARCHAR2,
        x_fetch_message                  OUT VARCHAR2,
        x_object_data_table              OUT AD_GROUP_DISPATCHER_TYPE
    );

    -- ── Sales Order CSV persister ─────────────────────────────────────────────
    -- Public wrapper — called directly by OIC (no EXECUTE IMMEDIATE overhead).
    -- Delegates to ACTUAL_PERSIST_SALES_ORDER_DATA.
    PROCEDURE PERSIST_SALES_ORDER_DATA
    (
        p_clob                        IN CLOB,
        p_oic_persister_instance_id   IN VARCHAR2,
        p_oic_persister_instance_name IN VARCHAR2
    );

    -- Inner implementation — public so it can be called directly for testing.
    PROCEDURE ACTUAL_PERSIST_SALES_ORDER_DATA
    (
        p_clob                        IN CLOB,
        p_oic_persister_instance_id   IN VARCHAR2,
        p_oic_persister_instance_name IN VARCHAR2
    );

END AD_PARKING_LOT_PKG;
