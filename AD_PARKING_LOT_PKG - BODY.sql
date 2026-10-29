create or replace PACKAGE BODY AD_PARKING_LOT_PKG AS

    -- =========================================================================
    -- Private types
    -- =========================================================================

    -- =========================================================================
    -- Encryption key for CLIENT_SECRET (AES256 CBC PKCS5)
    -- 32 bytes = 64 hex characters
    -- Generate with: SELECT RAWTOHEX(DBMS_CRYPTO.RANDOMBYTES(32)) FROM DUAL;
    -- Replace the value below with your own generated key before compiling.
    -- =========================================================================
    c_enc_key CONSTANT RAW(32) := HEXTORAW('0000000000000000000000000000000000000000000000000000000000000000');

    TYPE t_env_rec IS RECORD
    (
        env_id          AD_OIC_ENVIRONMENTS.ENV_ID%TYPE,
        base_url        AD_OIC_ENVIRONMENTS.BASE_URL%TYPE,
        max_msgs        AD_OIC_ENVIRONMENTS.MAX_MSGS%TYPE,
        running_count   NUMBER,       -- fetched once; -1 = API failed
        available_cap   NUMBER,       -- shared pool, decremented per interface
        fallback        VARCHAR2(1),
        bearer_token    VARCHAR2(4000) -- cached OAuth token for this run
    );
    TYPE t_env_tab IS TABLE OF t_env_rec INDEX BY PLS_INTEGER;

    TYPE t_intf_rec IS RECORD
    (
        interface_id   AD_INT_MASTER.INTERFACE_ID%TYPE,
        stage_number   AD_INT_MASTER.STAGE_NUMBER%TYPE,
        priority       AD_INT_MASTER.PRIORITY%TYPE,
        dispatch_type  AD_INT_MASTER.DISPATCH_TYPE%TYPE,
        max_msgs       AD_INT_MASTER.MAX_MSGS%TYPE  -- per-interface cap; NULL = no cap
    );
    TYPE t_intf_tab IS TABLE OF t_intf_rec INDEX BY PLS_INTEGER;


    -- =========================================================================
    -- p_log_error  (private)
    -- Writes a row to AD_ATP_ERRORS using an autonomous transaction so the
    -- log INSERT always commits regardless of the caller's rollback state.
    -- Must never raise — callers rely on it being silent on failure.
    -- =========================================================================
    PROCEDURE p_log_error
    (
        p_procedure_name IN VARCHAR2,
        p_error_code     IN NUMBER    DEFAULT NULL,
        p_error_message  IN VARCHAR2  DEFAULT NULL,
        p_interface_id   IN VARCHAR2  DEFAULT NULL,
        p_stage_number   IN NUMBER    DEFAULT NULL,
        p_msg_id         IN NUMBER    DEFAULT NULL,
        p_msg_sequence   IN NUMBER    DEFAULT NULL,
        p_notes          IN VARCHAR2  DEFAULT NULL
    )
    IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO AD_ATP_ERRORS
        (
            MSG_ID, MSG_SEQUENCE, INTERFACE_ID, STAGE_NUMBER,
            PROCEDURE_NAME,
            ERROR_CODE, ERROR_MESSAGE,
            NOTES
        )
        VALUES
        (
            p_msg_id, p_msg_sequence, p_interface_id, p_stage_number,
            p_procedure_name,
            p_error_code,
            SUBSTR(p_error_message, 1, 4000),
            SUBSTR(p_notes, 1, 1000)
        );
        COMMIT;
    EXCEPTION
        WHEN OTHERS THEN NULL;  -- logger must never raise
    END p_log_error;



    -- =========================================================================
    -- f_env_from_chunk
    -- Chunk format: <RUNID>_<WORKERNUM>_<ENVID>
    -- Splits from the right — safe when RUNID or ENVID contain underscores.
    -- =========================================================================
    FUNCTION f_env_from_chunk
    (
        p_chunk_id IN VARCHAR2
    ) RETURN VARCHAR2
    IS
    BEGIN
        RETURN SUBSTR(p_chunk_id, INSTR(p_chunk_id, '_', -1) + 1);
    EXCEPTION
        WHEN OTHERS THEN
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.f_env_from_chunk',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM,
                p_notes          => 'chunk_id=' || p_chunk_id
            );
            RETURN NULL;
    END f_env_from_chunk;

    -- =========================================================================
    -- f_encrypt_secret  (private)
    -- Encrypts a plain text secret using AES256 CBC PKCS5.
    -- Called by SET_ENV_CREDENTIALS when storing the client secret.
    -- =========================================================================
    FUNCTION f_encrypt_secret
    (
        p_plain_text IN VARCHAR2
    ) RETURN RAW
    IS
    BEGIN
        RETURN DBMS_CRYPTO.ENCRYPT
        (
            src => UTL_RAW.CAST_TO_RAW(p_plain_text),
            typ => DBMS_CRYPTO.ENCRYPT_AES256
                   + DBMS_CRYPTO.CHAIN_CBC
                   + DBMS_CRYPTO.PAD_PKCS5,
            key => c_enc_key
        );
    EXCEPTION
        WHEN OTHERS THEN
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.f_encrypt_secret',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM,
                p_notes          => 'AES256 encryption failed'
            );
            RETURN NULL;
    END f_encrypt_secret;


    -- =========================================================================
    -- f_decrypt_secret  (private)
    -- Decrypts an AES256 CBC PKCS5 encrypted RAW value back to VARCHAR2.
    -- Called by f_get_bearer_token at runtime — result never persisted.
    -- =========================================================================
    FUNCTION f_decrypt_secret
    (
        p_encrypted IN RAW
    ) RETURN VARCHAR2
    IS
    BEGIN
        IF p_encrypted IS NULL THEN
            RETURN NULL;
        END IF;
        RETURN UTL_RAW.CAST_TO_VARCHAR2
        (
            DBMS_CRYPTO.DECRYPT
            (
                src => p_encrypted,
                typ => DBMS_CRYPTO.ENCRYPT_AES256
                       + DBMS_CRYPTO.CHAIN_CBC
                       + DBMS_CRYPTO.PAD_PKCS5,
                key => c_enc_key
            )
        );
    EXCEPTION
        WHEN OTHERS THEN
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.f_decrypt_secret',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM,
                p_notes          => 'AES256 decryption failed'
            );
            DBMS_OUTPUT.PUT_LINE('f_decrypt_secret error: ' || SQLERRM);
            RETURN NULL;
    END f_decrypt_secret;


    -- =========================================================================
    -- f_get_bearer_token  (private)
    -- Returns a valid Bearer token for the given environment.
    -- Checks AD_OIC_ENVIRONMENTS.BEARER_TOKEN + TOKEN_EXPIRY first.
    -- Fetches a fresh token via UTL_HTTP when:
    --   - No cached token exists
    --   - Token expires within 60 seconds
    --   - p_force_fresh = TRUE (called on 401 retry)
    -- Updates BEARER_TOKEN + TOKEN_EXPIRY and COMMITs so chunk workers
    -- running in separate sessions can read the cached value.
    -- Returns NULL on any failure — caller should handle gracefully.
    -- =========================================================================
    FUNCTION f_get_bearer_token
    (
        p_env_id      IN AD_OIC_ENVIRONMENTS.ENV_ID%TYPE,
        p_force_fresh IN BOOLEAN DEFAULT FALSE
    ) RETURN VARCHAR2
    IS
        l_token         AD_OIC_ENVIRONMENTS.BEARER_TOKEN%TYPE;
        l_expiry        AD_OIC_ENVIRONMENTS.TOKEN_EXPIRY%TYPE;
        l_token_url     AD_OIC_ENVIRONMENTS.TOKEN_URL%TYPE;
        l_scope         AD_OIC_ENVIRONMENTS.TOKEN_SCOPE%TYPE;
        l_client_id     AD_OIC_ENVIRONMENTS.CLIENT_ID%TYPE;
        l_client_secret VARCHAR2(500);  -- decrypted at runtime, never persisted
        l_credentials   VARCHAR2(1000);
        l_post_body     VARCHAR2(1000);
        l_http_req      UTL_HTTP.REQ;
        l_http_resp     UTL_HTTP.RESP;
        l_buffer        VARCHAR2(32767);
        l_body_out      VARCHAR2(32767);
        l_new_token     VARCHAR2(4000);
    BEGIN

        -- Load env config — fetch CLIENT_SECRET as RAW, decrypt in PL/SQL
        -- (package functions cannot be called inside SQL within the same package)
        DECLARE
            l_secret_raw AD_OIC_ENVIRONMENTS.CLIENT_SECRET%TYPE;
        BEGIN
            SELECT BEARER_TOKEN, TOKEN_EXPIRY, TOKEN_URL, TOKEN_SCOPE,
                   CLIENT_ID, CLIENT_SECRET
              INTO l_token, l_expiry, l_token_url, l_scope,
                   l_client_id, l_secret_raw
              FROM AD_OIC_ENVIRONMENTS
             WHERE ENV_ID = p_env_id
               AND STATUS = 'A';
            l_client_secret := f_decrypt_secret(l_secret_raw);
        END;

        -- Return cached token if still valid (> 60 seconds remaining) and not forced
        IF     NOT p_force_fresh
           AND l_token  IS NOT NULL
           AND l_expiry IS NOT NULL
           AND l_expiry > SYSDATE + (60/86400)
        THEN
            RETURN l_token;
        END IF;

        -- Validate required fields
        IF l_token_url IS NULL OR l_scope IS NULL THEN
            DBMS_OUTPUT.PUT_LINE
            (
                'f_get_bearer_token: TOKEN_URL or TOKEN_SCOPE not configured for ['
                || p_env_id || ']'
            );
            RETURN NULL;
        END IF;

        IF l_client_id IS NULL OR l_client_secret IS NULL THEN
            DBMS_OUTPUT.PUT_LINE
            (
                'f_get_bearer_token: OAUTH_CLIENT_ID or OAUTH_CLIENT_SECRET not configured for ['
                || p_env_id || ']'
            );
            RETURN NULL;
        END IF;

        -- Base64 encode client_id:client_secret
        l_credentials := UTL_RAW.CAST_TO_VARCHAR2
                         (
                             UTL_ENCODE.BASE64_ENCODE
                             (
                                 UTL_RAW.CAST_TO_RAW(l_client_id || ':' || l_client_secret)
                             )
                         );
        l_credentials := REPLACE(REPLACE(l_credentials, CHR(13)), CHR(10));

        l_post_body := 'grant_type=client_credentials&scope=' || l_scope;

        -- Fetch token via UTL_HTTP
        UTL_HTTP.SET_TRANSFER_TIMEOUT(10);

        l_http_req := UTL_HTTP.BEGIN_REQUEST
                      (
                          url    => l_token_url,
                          method => 'POST'
                      );

        UTL_HTTP.SET_HEADER(l_http_req, 'Content-Type',   'application/x-www-form-urlencoded');
        UTL_HTTP.SET_HEADER(l_http_req, 'Authorization',  'Basic ' || l_credentials);
        UTL_HTTP.SET_HEADER(l_http_req, 'Content-Length', LENGTH(l_post_body));
        UTL_HTTP.WRITE_TEXT(l_http_req, l_post_body);

        l_http_resp := UTL_HTTP.GET_RESPONSE(l_http_req);

        BEGIN
            LOOP
                UTL_HTTP.READ_LINE(l_http_resp, l_buffer, FALSE);
                l_body_out := l_body_out || l_buffer;
            END LOOP;
        EXCEPTION
            WHEN UTL_HTTP.END_OF_BODY THEN NULL;
        END;

        UTL_HTTP.END_RESPONSE(l_http_resp);

        IF l_http_resp.status_code != 200 THEN
            DBMS_OUTPUT.PUT_LINE
            (
                'f_get_bearer_token: HTTP ' || l_http_resp.status_code
                || ' from ' || l_token_url
            );
            RETURN NULL;
        END IF;

        l_new_token := JSON_VALUE(l_body_out, '$.access_token');

        IF l_new_token IS NULL THEN
            DBMS_OUTPUT.PUT_LINE
            (
                'f_get_bearer_token: no access_token in response for [' || p_env_id || ']'
            );
            RETURN NULL;
        END IF;

        -- Cache token in AD_OIC_ENVIRONMENTS so chunk workers can read it
        UPDATE AD_OIC_ENVIRONMENTS
           SET BEARER_TOKEN = l_new_token,
               TOKEN_EXPIRY = SYSDATE + (3600/86400)  -- 1 hour
         WHERE ENV_ID = p_env_id;
        COMMIT;

        DBMS_OUTPUT.PUT_LINE
        (
            'f_get_bearer_token: fresh token obtained for [' || p_env_id
            || '] expires=' || TO_CHAR(SYSDATE + (3600/86400), 'HH24:MI:SS')
        );

        RETURN l_new_token;

    EXCEPTION
        WHEN OTHERS THEN
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.f_get_bearer_token',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM,
                p_notes          => 'env_id=' || p_env_id
            );
            DBMS_OUTPUT.PUT_LINE
            (
                'f_get_bearer_token error [' || p_env_id || ']: ' || SQLERRM
            );
            RETURN NULL;
    END f_get_bearer_token;


        -- =========================================================================
    -- GET_RUNNING_INSTANCES  (public)
    -- Invoked by a DBMS_SCHEDULER job spawned per environment in DISPATCH.
    -- Calls the custom OIC integration ADM_GET_NUMB_OF_RUNN_INST_IN_OIC which
    -- returns { "numberInstances": N }. Uses Bearer token (OAuth) when available,
    -- OAuth Bearer token required — no basic auth fallback.
    -- The custom integration runs inside OIC's own auth context.
    -- Writes numberInstances to AD_OIC_ENVIRONMENTS.LAST_RUNNING_COUNT + COMMITs
    -- so the DISPATCH polling loop (separate session) can read it.
    -- On any failure writes -1 so DISPATCH does not wait the full 5 seconds.
    -- =========================================================================
    PROCEDURE GET_RUNNING_INSTANCES
    (
        p_env_id IN AD_OIC_ENVIRONMENTS.ENV_ID%TYPE
    )
    IS
        l_base_url     AD_OIC_ENVIRONMENTS.BASE_URL%TYPE;
        l_bearer_token VARCHAR2(4000);
        l_response     DBMS_CLOUD_TYPES.RESP;
        l_body         CLOB;
        l_count        NUMBER := -1;
    BEGIN
        -- Resolve base URL
        SELECT BASE_URL
          INTO l_base_url
          FROM AD_OIC_ENVIRONMENTS
         WHERE ENV_ID = p_env_id
           AND STATUS = 'A';

        -- Get Bearer token (cached or fresh)
        l_bearer_token := f_get_bearer_token(p_env_id);

        IF l_bearer_token IS NULL THEN
            DBMS_OUTPUT.PUT_LINE
            (
                'GET_RUNNING_INSTANCES: no Bearer token for ['
                || p_env_id || '] — writing -1'
            );
        ELSE
            l_response := DBMS_CLOUD.SEND_REQUEST
            (
                credential_name => NULL,
                uri             => l_base_url
                                   || '/ic/api/integration/v1/flows/rest'
                                   || '/ADM_GET_NUMB_OF_RUNN_INST_IN_OIC/1.0/process',
                method          => DBMS_CLOUD.METHOD_GET,
                headers         => JSON_OBJECT
                                   (
                                       'Authorization' VALUE 'Bearer ' || l_bearer_token
                                   )
            );

            -- 401 — refresh token and retry once
            IF l_response.status_code = 401 THEN
                l_bearer_token := f_get_bearer_token
                                  (
                                      p_env_id      => p_env_id,
                                      p_force_fresh => TRUE
                                  );
                IF l_bearer_token IS NOT NULL THEN
                    l_response := DBMS_CLOUD.SEND_REQUEST
                    (
                        credential_name => NULL,
                        uri             => l_base_url
                                           || '/ic/api/integration/v1/flows/rest'
                                           || '/ADM_GET_NUMB_OF_RUNN_INST_IN_OIC/1.0/process',
                        method          => DBMS_CLOUD.METHOD_GET,
                        headers         => JSON_OBJECT
                                           (
                                               'Authorization' VALUE 'Bearer ' || l_bearer_token
                                           )
                    );
                END IF;
            END IF;
        END IF;

        IF l_response.status_code = 200 THEN
            l_body := DBMS_CLOUD.GET_RESPONSE_TEXT(l_response);
            SELECT NVL(JSON_VALUE(l_body, '$.numberInstances' RETURNING NUMBER), 0)
              INTO l_count
              FROM DUAL;
        ELSE
            DBMS_OUTPUT.PUT_LINE
            (
                'GET_RUNNING_INSTANCES: HTTP '
                || l_response.status_code || ' from ' || l_base_url
            );
        END IF;

        -- Write result (or -1 on failure) so DISPATCH polling loop can read it
        UPDATE AD_OIC_ENVIRONMENTS
           SET LAST_RUNNING_COUNT = l_count
         WHERE ENV_ID = p_env_id;
        COMMIT;

    EXCEPTION
        WHEN OTHERS THEN
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.GET_RUNNING_INSTANCES',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM,
                p_notes          => 'env_id=' || p_env_id
            );
            DBMS_OUTPUT.PUT_LINE
            (
                'GET_RUNNING_INSTANCES error [' || p_env_id || ']: ' || SQLERRM
            );
            -- Write -1 so DISPATCH does not wait the full 5 seconds for this env
            UPDATE AD_OIC_ENVIRONMENTS
               SET LAST_RUNNING_COUNT = -1
             WHERE ENV_ID = p_env_id;
            COMMIT;
    END GET_RUNNING_INSTANCES;


    -- =========================================================================
    -- f_validate_allocation
    -- Sums ALLOCATION_PCT for active env mappings for this interface+stage.
    -- Must equal 100.
    -- =========================================================================
    FUNCTION f_validate_allocation
    (
        p_interface_id IN VARCHAR2,
        p_stage_number IN NUMBER
    ) RETURN BOOLEAN
    IS
        l_total NUMBER;
    BEGIN
        SELECT NVL(SUM(m.ALLOCATION_PCT), 0)
          INTO l_total
          FROM AD_ENV_INT_MAP      m
          JOIN AD_OIC_ENVIRONMENTS e ON e.ENV_ID = m.ENV_ID
         WHERE m.INTERFACE_ID = p_interface_id
           AND m.STAGE_NUMBER = p_stage_number
           AND m.STATUS       = 'A'
           AND e.STATUS       = 'A';
        RETURN (l_total = 100);
    EXCEPTION
        WHEN OTHERS THEN
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.f_validate_allocation',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM,
                p_interface_id   => p_interface_id,
                p_stage_number   => p_stage_number
            );
            RETURN FALSE;
    END f_validate_allocation;


    -- =========================================================================
    -- f_compute_interface_quotas
    -- Computes final quota per env for one interface.
    -- Deducts from shared p_envs.available_cap pool.
    --
    -- Weight formula (DYNAMIC): allocation_pct / (running_count + c_weight_floor) where c_weight_floor=20
    --   Less busy env → higher weight → bigger share.
    -- =========================================================================
    PROCEDURE f_compute_interface_quotas
    (
        p_envs          IN OUT t_env_tab,
        p_env_count     IN     PLS_INTEGER,
        p_interface_id  IN     VARCHAR2,
        p_stage_number  IN     NUMBER,
        p_total_units   IN     NUMBER,          -- msgs (individual) or groups (group)
        p_interface_cap IN     NUMBER,          -- per-interface cap; NULL = no cap
        p_quotas        OUT    DBMS_SQL.NUMBER_TABLE
    )
    IS
        l_capped_units  NUMBER;
        TYPE t_alloc_rec IS RECORD
        (
            pct    NUMBER,
            atype  AD_ENV_INT_MAP.ALLOCATION_TYPE%TYPE,
            mapped BOOLEAN
        );
        TYPE t_alloc_tab IS TABLE OF t_alloc_rec INDEX BY PLS_INTEGER;

        c_weight_floor   CONSTANT NUMBER := 20;  -- dampens busyness sensitivity at low counts
        l_alloc          t_alloc_tab;
        l_dyn_weight_sum NUMBER := 0;
        l_assigned       NUMBER := 0;
        l_remainder      NUMBER;
        l_best_idx       PLS_INTEGER;
        l_best_headroom  NUMBER;
        l_headroom       NUMBER;
        l_weight         NUMBER;
    BEGIN

        -- Apply per-interface cap if configured.
        -- p_interface_cap NULL = no cap → use full p_total_units.
        -- Otherwise the effective work = LEAST(pending, cap). Excess stays QUEUED.
        l_capped_units := LEAST(p_total_units, NVL(p_interface_cap, p_total_units));

        IF l_capped_units < p_total_units THEN
            DBMS_OUTPUT.PUT_LINE
            (
                '  Interface cap applied: '
                || p_total_units || ' pending → ' || l_capped_units
                || ' dispatched this run (cap=' || p_interface_cap || ')'
            );
        END IF;

        -- Load per-interface allocation config in one query
        -- Default all envs to unmapped first
        FOR i IN 1 .. p_env_count LOOP
            l_alloc(i).mapped := FALSE;
            l_alloc(i).pct    := 0;
            l_alloc(i).atype  := 'STATIC';
            p_quotas(i)       := 0;
        END LOOP;

        FOR r IN
        (
            SELECT m.ENV_ID, m.ALLOCATION_PCT, m.ALLOCATION_TYPE
              FROM AD_ENV_INT_MAP m
             WHERE m.INTERFACE_ID = p_interface_id
               AND m.STAGE_NUMBER = p_stage_number
               AND m.STATUS       = 'A'
        )
        LOOP
            FOR i IN 1 .. p_env_count LOOP
                IF p_envs(i).env_id = r.ENV_ID THEN
                    l_alloc(i).pct    := r.ALLOCATION_PCT;
                    l_alloc(i).atype  := r.ALLOCATION_TYPE;
                    l_alloc(i).mapped := TRUE;
                    EXIT;
                END IF;
            END LOOP;
        END LOOP;

        -- Dynamic weight sum
        -- weight = allocation_pct / (running_count + c_weight_floor)
        -- Floor of 10 dampens sensitivity at low running counts so that
        -- small differences (e.g. 0 vs 2 instances) do not cause extreme splits.
        -- allocation_pct anchors the base split; busyness bends it proportionally.
        -- Fallback (timeout/API fail): weight = allocation_pct / 1 — treated as
        -- least busy possible, gets proportionally more msgs as a safe default.
        FOR i IN 1 .. p_env_count LOOP
            IF     l_alloc(i).mapped
               AND l_alloc(i).atype      = 'DYNAMIC'
               AND p_envs(i).available_cap > 0
            THEN
                l_dyn_weight_sum :=
                    l_dyn_weight_sum
                    + (l_alloc(i).pct /
                       (CASE WHEN p_envs(i).running_count = -1
                             THEN c_weight_floor   -- timeout = assume 0 running
                             ELSE p_envs(i).running_count + c_weight_floor
                        END));
            END IF;
        END LOOP;

        -- Assign quota per env
        FOR i IN 1 .. p_env_count LOOP
            IF NOT l_alloc(i).mapped THEN CONTINUE; END IF;

            IF p_envs(i).available_cap <= 0 THEN
                p_quotas(i) := 0;

            ELSIF l_alloc(i).atype = 'STATIC' THEN
                p_quotas(i) := LEAST
                (
                    FLOOR(l_capped_units * l_alloc(i).pct / 100),
                    p_envs(i).available_cap
                );

            ELSIF l_dyn_weight_sum = 0 THEN
                p_quotas(i) := LEAST
                (
                    FLOOR(l_capped_units / p_env_count),
                    p_envs(i).available_cap
                );

            ELSE
                -- API failed → fallback weight = pct/1, flag for logging
                IF p_envs(i).running_count = -1 THEN
                    p_envs(i).fallback := 'Y';
                END IF;
                l_weight := l_alloc(i).pct /
                            (CASE WHEN p_envs(i).running_count = -1
                                  THEN c_weight_floor   -- timeout = assume 0 running
                                  ELSE p_envs(i).running_count + c_weight_floor
                             END);
                p_quotas(i) := LEAST
                (
                    FLOOR(l_capped_units * l_weight / l_dyn_weight_sum),
                    p_envs(i).available_cap
                );
            END IF;

            l_assigned := l_assigned + p_quotas(i);
        END LOOP;

        -- Distribute FLOOR remainder
        l_remainder := l_capped_units - l_assigned;
        WHILE l_remainder > 0 LOOP
            l_best_idx      := NULL;
            l_best_headroom := -1;
            FOR i IN 1 .. p_env_count LOOP
                IF NOT l_alloc(i).mapped THEN CONTINUE; END IF;
                l_headroom := p_envs(i).available_cap - p_quotas(i);
                IF l_headroom > 0 AND l_headroom > l_best_headroom THEN
                    l_best_headroom := l_headroom;
                    l_best_idx      := i;
                END IF;
            END LOOP;
            EXIT WHEN l_best_idx IS NULL;
            p_quotas(l_best_idx) := p_quotas(l_best_idx) + 1;
            l_remainder          := l_remainder - 1;
        END LOOP;

        -- Log final quotas AFTER remainder distribution so values match dispatch
        FOR i IN 1 .. p_env_count LOOP
            IF NOT l_alloc(i).mapped THEN CONTINUE; END IF;
            DBMS_OUTPUT.PUT_LINE
            (
                '  ENV [' || p_envs(i).env_id
                || '] type='    || l_alloc(i).atype
                || CASE WHEN p_envs(i).fallback = 'Y' THEN '(fallback)' ELSE '' END
                || ' running='  || NVL(TO_CHAR(p_envs(i).running_count), 'N/A')
                || ' pool='     || p_envs(i).available_cap
                || ' quota='    || p_quotas(i)
            );
        END LOOP;

        -- Deduct from shared pool
        FOR i IN 1 .. p_env_count LOOP
            p_envs(i).available_cap := p_envs(i).available_cap - p_quotas(i);
        END LOOP;

        DBMS_OUTPUT.PUT_LINE
        (
            '  Total units: '   || p_total_units
            || '  Assigned: '   || (l_capped_units - l_remainder)
            || '  Left QUEUED: '|| (p_total_units - (l_capped_units - l_remainder))
        );

    EXCEPTION
        WHEN OTHERS THEN
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.f_compute_interface_quotas',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM,
                p_interface_id   => p_interface_id,
                p_stage_number   => p_stage_number
            );
            RAISE;
    END f_compute_interface_quotas;


    -- =========================================================================
    -- p_submit_job
    -- Shared helper: submit a DBMS_SCHEDULER job with up to 5 retries.
    -- On permanent failure marks all msgs in that chunk as ERROR.
    -- =========================================================================
    PROCEDURE p_submit_job
    (
        p_job_name   IN VARCHAR2,
        p_chunk_id   IN VARCHAR2,
        p_procedure  IN VARCHAR2    -- 'DISPATCH_INDIVIDUAL_CHUNK' or 'DISPATCH_GROUP_CHUNK'
    )
    IS
        c_max_retry CONSTANT PLS_INTEGER := 5;
        l_attempt   PLS_INTEGER := 1;
        l_submitted VARCHAR2(1) := 'N';
        l_err_msg   VARCHAR2(2000);
    BEGIN
        WHILE l_submitted = 'N' AND l_attempt <= c_max_retry LOOP
            BEGIN
                DBMS_SCHEDULER.CREATE_JOB
                (
                    job_name   => p_job_name,
                    job_type   => 'PLSQL_BLOCK',
                    job_action =>
                        'BEGIN AD_PARKING_LOT_PKG.' || p_procedure || '('''
                        || p_chunk_id || '''); END;',
                    start_date => SYSTIMESTAMP,
                    enabled    => TRUE,
                    auto_drop  => TRUE
                );
                l_submitted := 'Y';
                DBMS_OUTPUT.PUT_LINE
                (
                    '  Job submitted: ' || p_job_name
                    || ' chunk=' || p_chunk_id
                );
            EXCEPTION
                WHEN OTHERS THEN
                    l_err_msg := SUBSTR(SQLERRM, 1, 2000);
                    p_log_error
                    (
                        p_procedure_name => 'AD_PARKING_LOT_PKG.p_submit_job',
                        p_error_code     => SQLCODE,
                        p_error_message  => SQLERRM,
                        p_notes          => 'attempt=' || l_attempt
                                            || ' job=' || p_job_name
                                            || ' chunk_id=' || p_chunk_id
                    );
                    DBMS_OUTPUT.PUT_LINE
                    (
                        '  Attempt ' || l_attempt
                        || ' failed for ' || p_job_name
                        || ': ' || l_err_msg
                    );
                    DBMS_SESSION.SLEEP(l_attempt);
                    l_attempt := l_attempt + 1;
            END;
        END LOOP;

        IF l_submitted = 'N' THEN
            UPDATE AD_MSG_AUDIT
               SET STATUS           = 'ERROR',
                   ERROR_MESSAGE    = SUBSTR
                                      (
                                          'Job submission failed after '
                                          || c_max_retry
                                          || ' attempts: ' || l_err_msg,
                                          1, 30000
                                      ),
                   LAST_UPDATE_DATE = SYSDATE
             WHERE CHUNK_ID = p_chunk_id
               AND STATUS   = 'PROCESSING';
            COMMIT;
            DBMS_OUTPUT.PUT_LINE
            (
                '  Chunk marked ERROR (job never submitted): ' || p_chunk_id
            );
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.p_submit_job',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM,
                p_notes          => 'job=' || p_job_name || ' chunk_id=' || p_chunk_id
            );
            RAISE;
    END p_submit_job;


    -- =========================================================================
    -- p_dispatch_individual_intf
    -- Handles ATP_INDIVIDUAL routing for one interface.
    -- Chunks of max 50 msgs, one scheduler job per chunk.
    -- =========================================================================
    PROCEDURE p_dispatch_individual_intf
    (
        p_envs          IN OUT t_env_tab,
        p_env_count     IN     PLS_INTEGER,
        p_interface_id  IN     VARCHAR2,
        p_stage_number  IN     NUMBER,
        p_interface_cap IN     NUMBER,
        p_run_id        IN     VARCHAR2,
        p_global_worker IN OUT NUMBER
    )
    IS
        TYPE t_num_tab        IS TABLE OF NUMBER;
        TYPE t_vc200_tab      IS TABLE OF VARCHAR2(200);
        TYPE t_env_cursor_tab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

        CURSOR c_pending IS
            SELECT a.MSG_ID
              FROM AD_MSG_AUDIT  a
              JOIN AD_INT_MASTER m
                ON  m.INTERFACE_ID = a.INTERFACE_ID
               AND  m.STAGE_NUMBER = a.STAGE_NUMBER
             WHERE a.INTERFACE_ID   = p_interface_id
               AND a.STAGE_NUMBER   = p_stage_number
               AND a.STATUS         = 'READY_TO_DISPATCH'
               AND m.STATUS         = 'A'
               AND m.OUTAGE         = 'N'
               AND m.DISPATCH_TYPE  = 'ATP_INDIVIDUAL'
             ORDER BY m.PRIORITY, a.MSG_ID;

        c_batch_size  CONSTANT PLS_INTEGER := 50;
        c_fetch_limit CONSTANT PLS_INTEGER := 1000;

        l_quotas       DBMS_SQL.NUMBER_TABLE;
        l_env_assigned t_env_cursor_tab;
        l_all_msg_ids  t_num_tab   := t_num_tab();
        l_all_chunks   t_vc200_tab := t_vc200_tab();
        l_fetched_ids  t_num_tab;
        l_total        PLS_INTEGER := 0;
        l_env_idx      PLS_INTEGER;
        l_job_name     VARCHAR2(128);
        -- Associative array keyed by chunk_id for O(n) uniqueness check
        TYPE t_chunk_seen_tab IS TABLE OF NUMBER INDEX BY VARCHAR2(200);
        l_seen_chunks  t_chunk_seen_tab;

    BEGIN

        -- Fetch all pending MSG_IDs
        OPEN c_pending;
        LOOP
            FETCH c_pending BULK COLLECT INTO l_fetched_ids LIMIT c_fetch_limit;
            EXIT WHEN l_fetched_ids.COUNT = 0;
            l_all_msg_ids.EXTEND(l_fetched_ids.COUNT);
            FOR i IN 1 .. l_fetched_ids.COUNT LOOP
                l_total := l_total + 1;
                l_all_msg_ids(l_total) := l_fetched_ids(i);
            END LOOP;
            EXIT WHEN c_pending%NOTFOUND;
        END LOOP;
        CLOSE c_pending;

        IF l_total = 0 THEN
            DBMS_OUTPUT.PUT_LINE('  No pending msgs — skipping.');
            RETURN;
        END IF;

        DBMS_OUTPUT.PUT_LINE('  Pending msgs: ' || l_total);

        -- Compute quotas (deducts from shared pool)
        FOR i IN 1 .. p_env_count LOOP
            l_env_assigned(i) := 0;
        END LOOP;

        f_compute_interface_quotas
        (
            p_envs          => p_envs,
            p_env_count     => p_env_count,
            p_interface_id  => p_interface_id,
            p_stage_number  => p_stage_number,
            p_total_units   => l_total,
            p_interface_cap => p_interface_cap,
            p_quotas        => l_quotas
        );

        -- Assign CHUNK_ID per message
        l_all_chunks.EXTEND(l_total);

        l_env_idx := 1;
        WHILE l_env_idx <= p_env_count
          AND NVL(l_quotas(l_env_idx), 0) = 0
        LOOP
            l_env_idx := l_env_idx + 1;
        END LOOP;

        FOR i IN 1 .. l_total LOOP
            WHILE l_env_idx <= p_env_count
              AND l_env_assigned(l_env_idx) >= NVL(l_quotas(l_env_idx), 0)
            LOOP
                l_env_idx := l_env_idx + 1;
            END LOOP;

            IF l_env_idx > p_env_count THEN
                l_all_chunks(i) := NULL;
            ELSE
                IF MOD(l_env_assigned(l_env_idx), c_batch_size) = 0 THEN
                    p_global_worker := p_global_worker + 1;
                END IF;
                l_all_chunks(i) :=
                    p_run_id
                    || '_' || p_global_worker
                    || '_' || p_envs(l_env_idx).env_id;
                l_env_assigned(l_env_idx) := l_env_assigned(l_env_idx) + 1;
            END IF;
        END LOOP;

        -- Single FORALL bulk UPDATE
        FORALL i IN 1 .. l_total
            UPDATE AD_MSG_AUDIT
               SET STATUS           = CASE WHEN l_all_chunks(i) IS NOT NULL THEN 'PROCESSING' ELSE STATUS END,
                   CHUNK_ID         = CASE WHEN l_all_chunks(i) IS NOT NULL THEN l_all_chunks(i) ELSE CHUNK_ID END,
                   LAST_UPDATE_DATE = CASE WHEN l_all_chunks(i) IS NOT NULL THEN SYSDATE ELSE LAST_UPDATE_DATE END
             WHERE MSG_ID  = l_all_msg_ids(i)
               AND STATUS = 'READY_TO_DISPATCH';

        COMMIT;

        -- Spawn one job per unique chunk using associative array for O(n) dedup
        FOR i IN 1 .. l_total LOOP
            IF l_all_chunks(i) IS NULL THEN CONTINUE; END IF;
            IF NOT l_seen_chunks.EXISTS(l_all_chunks(i)) THEN
                l_seen_chunks(l_all_chunks(i)) := 1;
                l_job_name := SUBSTR('AD_DISP_IND_' || p_run_id || '_' || l_seen_chunks.COUNT, 1, 128);
                p_submit_job(l_job_name, l_all_chunks(i), 'DISPATCH_INDIVIDUAL_CHUNK');
            END IF;
        END LOOP;

    EXCEPTION
        WHEN OTHERS THEN
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.p_dispatch_individual_intf',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM,
                p_interface_id   => p_interface_id,
                p_stage_number   => p_stage_number
            );
            IF c_pending%ISOPEN THEN CLOSE c_pending; END IF;
            RAISE;
    END p_dispatch_individual_intf;


    -- =========================================================================
    -- p_dispatch_group_intf
    -- Handles ATP_GROUP routing for one interface.
    -- Group = unique (MSG_SEQUENCE, INTERFACE_ID, STAGE_NUMBER).
    -- One OIC instance per group = one DBMS_SCHEDULER job per group.
    -- All msgs in a group share the same CHUNK_ID.
    -- =========================================================================
    PROCEDURE p_dispatch_group_intf
    (
        p_envs          IN OUT t_env_tab,
        p_env_count     IN     PLS_INTEGER,
        p_interface_id  IN     VARCHAR2,
        p_stage_number  IN     NUMBER,
        p_interface_cap IN     NUMBER,
        p_run_id        IN     VARCHAR2,
        p_global_worker IN OUT NUMBER
    )
    IS
        -- One row per distinct group
        TYPE t_group_rec IS RECORD
        (
            msg_sequence  AD_MSG_AUDIT.MSG_SEQUENCE%TYPE,
            sub_group_id  AD_MSG_AUDIT.MSG_SUB_GROUP_ID%TYPE
        );
        TYPE t_group_tab IS TABLE OF t_group_rec;

        TYPE t_num_tab   IS TABLE OF NUMBER;
        TYPE t_vc200_tab IS TABLE OF VARCHAR2(200);

        -- Distinct groups with pending msgs
        CURSOR c_groups IS
            SELECT DISTINCT
                   a.MSG_SEQUENCE,
                   a.MSG_SUB_GROUP_ID
              FROM AD_MSG_AUDIT  a
              JOIN AD_INT_MASTER m
                ON  m.INTERFACE_ID = a.INTERFACE_ID
               AND  m.STAGE_NUMBER = a.STAGE_NUMBER
             WHERE a.INTERFACE_ID   = p_interface_id
               AND a.STAGE_NUMBER   = p_stage_number
               AND a.STATUS         = 'READY_TO_DISPATCH'
               AND m.STATUS         = 'A'
               AND m.OUTAGE         = 'N'
               AND m.DISPATCH_TYPE  = 'ATP_GROUP'
             ORDER BY a.MSG_SEQUENCE, a.MSG_SUB_GROUP_ID;

        l_groups       t_group_tab;
        l_total_groups PLS_INTEGER := 0;
        l_quotas       DBMS_SQL.NUMBER_TABLE;

        -- Per-env group counter (tracks how many groups assigned to each env)
        TYPE t_env_cursor_tab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
        l_env_grp_count t_env_cursor_tab;

        l_env_idx      PLS_INTEGER;
        l_chunk_id     VARCHAR2(200);
        l_job_name     VARCHAR2(128);

    BEGIN

        -- Fetch all distinct groups
        OPEN c_groups;
        FETCH c_groups BULK COLLECT INTO l_groups;
        CLOSE c_groups;

        l_total_groups := l_groups.COUNT;

        IF l_total_groups = 0 THEN
            DBMS_OUTPUT.PUT_LINE('  No pending groups — skipping.');
            RETURN;
        END IF;

        DBMS_OUTPUT.PUT_LINE('  Pending groups: ' || l_total_groups);

        -- Compute quotas using group count as the unit
        -- (each "unit" = one group = one OIC instance)
        FOR i IN 1 .. p_env_count LOOP
            l_env_grp_count(i) := 0;
        END LOOP;

        f_compute_interface_quotas
        (
            p_envs          => p_envs,
            p_env_count     => p_env_count,
            p_interface_id  => p_interface_id,
            p_stage_number  => p_stage_number,
            p_total_units   => l_total_groups,
            p_interface_cap => p_interface_cap,
            p_quotas        => l_quotas
        );

        -- Advance to first env with quota > 0
        l_env_idx := 1;
        WHILE l_env_idx <= p_env_count
          AND NVL(l_quotas(l_env_idx), 0) = 0
        LOOP
            l_env_idx := l_env_idx + 1;
        END LOOP;

        -- Assign one chunk per group, one job per group
        FOR g IN 1 .. l_total_groups LOOP

            -- Roll to next env when quota exhausted
            WHILE l_env_idx <= p_env_count
              AND l_env_grp_count(l_env_idx) >= NVL(l_quotas(l_env_idx), 0)
            LOOP
                l_env_idx := l_env_idx + 1;
            END LOOP;

            IF l_env_idx > p_env_count THEN
                -- All env quotas filled; remaining groups stay QUEUED
                DBMS_OUTPUT.PUT_LINE
                (
                    '  Group MSG_SEQ=' || l_groups(g).msg_sequence
                    || ' stays READY_TO_DISPATCH (quota exhausted — deferred to next run)'
                );
                CONTINUE;
            END IF;

            -- Each group gets its own worker number → unique CHUNK_ID
            p_global_worker := p_global_worker + 1;

            l_chunk_id :=
                p_run_id
                || '_' || p_global_worker
                || '_' || p_envs(l_env_idx).env_id;

            -- Mark ALL msgs in this group as PROCESSING with the shared CHUNK_ID
            UPDATE AD_MSG_AUDIT
               SET STATUS           = 'PROCESSING',
                   CHUNK_ID         = l_chunk_id,
                   LAST_UPDATE_DATE = SYSDATE
             WHERE INTERFACE_ID     = p_interface_id
               AND STAGE_NUMBER     = p_stage_number
               AND MSG_SEQUENCE     = l_groups(g).msg_sequence
               AND NVL(MSG_SUB_GROUP_ID, -1) =
                       NVL(l_groups(g).sub_group_id, -1)
               AND STATUS           = 'READY_TO_DISPATCH';

            COMMIT;

            -- One scheduler job per group
            l_job_name :=
                SUBSTR('AD_DISP_GRP_' || p_run_id || '_' || p_global_worker, 1, 128);

            p_submit_job(l_job_name, l_chunk_id, 'DISPATCH_GROUP_CHUNK');

            l_env_grp_count(l_env_idx) := l_env_grp_count(l_env_idx) + 1;

        END LOOP;

    EXCEPTION
        WHEN OTHERS THEN
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.p_dispatch_group_intf',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM,
                p_interface_id   => p_interface_id,
                p_stage_number   => p_stage_number
            );
            IF c_groups%ISOPEN THEN CLOSE c_groups; END IF;
            RAISE;
    END p_dispatch_group_intf;



    -- =========================================================================
    -- GET_TOKEN_FOR_TEST  (public)
    -- Returns a fresh Bearer token for the given env. Test use only.
    -- =========================================================================
    FUNCTION GET_TOKEN_FOR_TEST
    (
        p_env_id IN AD_OIC_ENVIRONMENTS.ENV_ID%TYPE
    ) RETURN VARCHAR2
    IS
    BEGIN
        RETURN f_get_bearer_token
               (
                   p_env_id      => p_env_id,
                   p_force_fresh => TRUE
               );
    EXCEPTION
        WHEN OTHERS THEN
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.GET_TOKEN_FOR_TEST',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM,
                p_notes          => 'env_id=' || p_env_id
            );
            RETURN NULL;
    END GET_TOKEN_FOR_TEST;


    -- =========================================================================
    -- SET_ENV_CREDENTIALS  (public)
    -- Encrypts p_client_secret and writes CLIENT_ID + CLIENT_SECRET to
    -- AD_OIC_ENVIRONMENTS for the given ENV_ID.
    -- Never store the secret in plain text — always call this procedure.
    -- =========================================================================
    PROCEDURE SET_ENV_CREDENTIALS
    (
        p_env_id        IN AD_OIC_ENVIRONMENTS.ENV_ID%TYPE,
        p_client_id     IN VARCHAR2,
        p_client_secret IN VARCHAR2
    )
    IS
    BEGIN
        -- Encrypt in PL/SQL first — package functions cannot be called in SQL DML
        DECLARE
            l_encrypted_secret RAW(500);
        BEGIN
            l_encrypted_secret := f_encrypt_secret(p_client_secret);
            UPDATE AD_OIC_ENVIRONMENTS
               SET CLIENT_ID     = p_client_id,
                   CLIENT_SECRET = l_encrypted_secret
             WHERE ENV_ID = p_env_id;
        END;

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'ENV_ID not found: ' || p_env_id);
        END IF;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE
        (
            'SET_ENV_CREDENTIALS: credentials stored for [' || p_env_id || ']'
        );
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.SET_ENV_CREDENTIALS',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM,
                p_notes          => 'env_id=' || p_env_id
            );
            DBMS_OUTPUT.PUT_LINE
            (
                'SET_ENV_CREDENTIALS error [' || p_env_id || ']: ' || SQLERRM
            );
            RAISE;
    END SET_ENV_CREDENTIALS;


    -- =========================================================================
    -- F_NEXT_DISPATCH_DATE  (public — SQL-callable)
    -- Evaluates pipe-separated DBMS_SCHEDULER calendar expressions to determine
    -- the earliest next-fire DATE for an interface, anchored to the last time
    -- messages were dispatched.
    --
    -- Returns SYSDATE-1 when p_dispatch_frequency IS NULL (always due).
    -- Returns NULL on evaluation error (safe default: NULL <= SYSDATE = FALSE).
    --
    -- Called inside SEQUENCE_MSGS MERGE USING clauses:
    --   AND (m.DISPATCH_FREQUENCY IS NULL
    --        OR AD_PARKING_LOT_PKG.F_NEXT_DISPATCH_DATE(
    --               m.DISPATCH_FREQUENCY, m.LAST_DISPATCHED_DATE) <= SYSDATE)
    -- =========================================================================
    FUNCTION F_NEXT_DISPATCH_DATE
    (
        p_dispatch_frequency   IN VARCHAR2,
        p_last_dispatched_date IN DATE
    ) RETURN DATE
    IS
        l_next_run   TIMESTAMP WITH TIME ZONE;
        l_anchor     TIMESTAMP WITH TIME ZONE;
        l_earliest   DATE        := NULL;
        l_pos        PLS_INTEGER := 1;
        l_pipe       PLS_INTEGER;
        l_expr       VARCHAR2(4000);
    BEGIN
        -- NULL frequency = no gate; always due
        IF p_dispatch_frequency IS NULL THEN
            RETURN SYSDATE - 1;
        END IF;

        -- Anchor: last dispatch, or ~1 year ago so first-ever run is always due
        l_anchor := CAST(NVL(p_last_dispatched_date, SYSDATE - 366) AS TIMESTAMP WITH TIME ZONE);

        LOOP
            l_pipe := INSTR(p_dispatch_frequency, '|', l_pos);

            IF l_pipe = 0 THEN
                l_expr := SUBSTR(p_dispatch_frequency, l_pos);
            ELSE
                l_expr := SUBSTR(p_dispatch_frequency, l_pos, l_pipe - l_pos);
            END IF;

            l_expr := TRIM(l_expr);

            IF l_expr IS NOT NULL THEN
                DBMS_SCHEDULER.EVALUATE_CALENDAR_STRING
                (
                    calendar_string   => l_expr,
                    start_date        => l_anchor,
                    return_date_after => l_anchor,
                    next_run_date     => l_next_run
                );
                -- OR logic: keep the earliest next-fire across all expressions
                IF l_earliest IS NULL OR CAST(l_next_run AS DATE) < l_earliest THEN
                    l_earliest := CAST(l_next_run AS DATE);
                END IF;
            END IF;

            EXIT WHEN l_pipe = 0;
            l_pos := l_pipe + 1;
        END LOOP;

        RETURN l_earliest;

    EXCEPTION
        WHEN OTHERS THEN
            -- Safe default: NULL <= SYSDATE = FALSE, so the interface is skipped
            RETURN NULL;
    END F_NEXT_DISPATCH_DATE;


    -- =========================================================================
    -- SEQUENCE_MSGS  (public)
    -- Called at the start of DISPATCH. Promotes eligible msgs from
    -- QUEUED/RETRY to READY_TO_DISPATCH in three set-based statements:
    --
    --   Part A  ATP_INDIVIDUAL — single MERGE, one pass over AD_MSG_AUDIT.
    --     All blocking logic (PROCESSING in-flight, lowest MSG_SEQUENCE,
    --     WAITING_TIME, dedup to lowest MSG_ID per business key) resolved
    --     analytically inside the USING clause. No DB_JOB_ID tagging.
    --     3 passes → 1 pass.
    --
    --   Part B1 ATP_GROUP PARALLEL — single MERGE with inline JOIN.
    --     No correlated EXISTS. One pass.
    --
    --   Part B2 ATP_GROUP SERIAL — single MERGE with inline analytics.
    --     Minimum eligible sequence per interface derived set-based.
    --     No row-by-row loop.
    --
    -- Cross-interface dependency gate (AD_INT_DEPENDENCIES):
    --   All three parts share a blocked_keys CTE that identifies
    --   (INTERFACE_ID, STAGE_NUMBER, BUSINESS_IDENTIFIER1) combinations
    --   whose prerequisite interface still has non-terminal messages
    --   (STATUS NOT IN ('PROCESSED','ERROR')).  Candidates matching a
    --   blocked key are excluded from promotion and remain QUEUED/RETRY
    --   until the prerequisite drains.  Only active dependency rules
    --   (STATUS = 'A') are evaluated.
    -- =========================================================================
    PROCEDURE SEQUENCE_MSGS
    IS
    BEGIN

        DBMS_OUTPUT.PUT_LINE('SEQUENCE_MSGS started ' || SYSTIMESTAMP);

        -- ══════════════════════════════════════════════════════════════════════
        -- PART A: ATP_INDIVIDUAL — single MERGE, two-set join
        --
        -- Rule: promote a QUEUED/RETRY row to READY_TO_DISPATCH only when
        -- no row with a lower MSG_ID exists for the same
        -- (INTERFACE_ID, BUSINESS_IDENTIFIER1) in PROCESSING or
        -- READY_TO_DISPATCH status, AND the cross-interface dependency
        -- gate (AD_INT_DEPENDENCIES) is satisfied for this business key,
        -- AND the dispatch frequency gate (F_NEXT_DISPATCH_DATE) allows it.
        --
        -- Implementation: two small scans joined — avoids scanning the large
        -- READY_TO_DISPATCH set together with QUEUED/RETRY candidates:
        --   1. active_mins: aggregate MIN(MSG_ID) per key over PROCESSING +
        --      READY_TO_DISPATCH only — small GROUP BY, no window function
        --   2. candidates: QUEUED/RETRY rows joined to AD_INT_MASTER — small
        --      (only interfaces whose DISPATCH_FREQUENCY is NULL or past-due)
        --   3. blocked_keys: (INTERFACE_ID, STAGE_NUMBER, BUSINESS_IDENTIFIER1)
        --      tuples whose prerequisite interface still has open messages
        --   4. LEFT JOIN active_mins: eligible when no active row has lower MSG_ID
        --      AND the key is not present in blocked_keys
        --
        -- No WAITING_TIME check. No MSG_SEQUENCE blocking. No ROW_NUMBER dedup.
        -- DB_JOB_ID not used.
        -- ══════════════════════════════════════════════════════════════════════
        MERGE /*+ enable_parallel_dml parallel(4) */
         INTO AD_MSG_AUDIT tgt
        USING
        (
            -- Step 1: minimum active MSG_ID per (INTERFACE_ID, BUSINESS_IDENTIFIER1)
            -- Only reads PROCESSING + READY_TO_DISPATCH rows — typically small set
            WITH active_mins AS
            (
                SELECT INTERFACE_ID,
                       BUSINESS_IDENTIFIER1,
                       MIN(MSG_ID) AS min_msg_id
                  FROM AD_MSG_AUDIT
                 WHERE STATUS IN ('PROCESSING', 'READY_TO_DISPATCH')
                 GROUP BY INTERFACE_ID, BUSINESS_IDENTIFIER1
            ),
            -- Step 2: candidate rows — QUEUED/RETRY joined to eligible interfaces
            -- Frequency gate applied here: skip interfaces not yet due for dispatch
            candidates AS
            (
                SELECT a.ROWID  AS row_id,
                       a.MSG_ID,
                       a.INTERFACE_ID,
                       a.STAGE_NUMBER,
                       a.BUSINESS_IDENTIFIER1
                  FROM AD_MSG_AUDIT  a
                  JOIN AD_INT_MASTER m
                    ON  m.INTERFACE_ID       = a.INTERFACE_ID
                   AND  m.STAGE_NUMBER       = a.STAGE_NUMBER
                   AND  m.DISPATCH_TYPE      = 'ATP_INDIVIDUAL'
                   AND  m.INTERFACE_CATEGORY IN ('Processor', 'PostProcessor')
                   AND  m.STATUS             = 'A'
                   AND  (   m.DISPATCH_FREQUENCY IS NULL
                         OR F_NEXT_DISPATCH_DATE(m.DISPATCH_FREQUENCY, m.LAST_DISPATCHED_DATE) <= SYSDATE)
                 WHERE a.STATUS IN ('QUEUED', 'RETRY')
            ),
            -- Step 3: blocked keys — prerequisite interface has non-terminal messages.
            -- Global blocking: any non-terminal prereq message blocks the entire
            -- dependent interface regardless of BUSINESS_IDENTIFIER1.
            blocked_keys AS
            (
                SELECT DISTINCT
                       d.INTERFACE_ID,
                       d.STAGE_NUMBER
                  FROM AD_INT_DEPENDENCIES d
                  JOIN AD_MSG_AUDIT        prereq
                    ON  prereq.INTERFACE_ID  = d.DEPENDS_ON_INTERFACE_ID
                   AND  prereq.STAGE_NUMBER  = d.DEPENDS_ON_STAGE_NUMBER
                   AND  prereq.STATUS       NOT IN ('PROCESSED', 'ERROR')
                 WHERE d.STATUS = 'A'
            )
            -- Step 4: left join — eligible when no active row has lower MSG_ID
            --         AND this (interface, stage, business key) is not blocked
            SELECT c.row_id
              FROM candidates       c
              LEFT JOIN active_mins a
                ON  a.INTERFACE_ID        = c.INTERFACE_ID
               AND  a.BUSINESS_IDENTIFIER1 = c.BUSINESS_IDENTIFIER1
              LEFT JOIN blocked_keys      bk
                ON  bk.INTERFACE_ID        = c.INTERFACE_ID
               AND  bk.STAGE_NUMBER        = c.STAGE_NUMBER
             WHERE bk.INTERFACE_ID IS NULL          -- dependency gate: not blocked
               AND (   a.min_msg_id IS NULL         -- no active row for this key
                    OR c.MSG_ID < a.min_msg_id)     -- candidate is lower than any active
        ) src
        ON (tgt.ROWID = src.row_id)
        WHEN MATCHED THEN
            UPDATE SET tgt.STATUS           = 'READY_TO_DISPATCH',
                       tgt.LAST_UPDATE_DATE = SYSDATE;

        -- ══════════════════════════════════════════════════════════════════════
        -- PART B1: ATP_GROUP PARALLEL — single MERGE, inline JOIN
        -- Replaces correlated EXISTS with a join inside the USING clause.
        -- One pass over AD_MSG_AUDIT for QUEUED/RETRY group rows.
        -- Dependency gate: blocked_keys CTE excludes rows whose prerequisite
        -- interface still has non-terminal messages (global blocking).
        -- ══════════════════════════════════════════════════════════════════════
        MERGE /*+ enable_parallel_dml parallel(4) */
         INTO AD_MSG_AUDIT tgt
        USING
        (
            WITH blocked_keys AS
            (
                SELECT DISTINCT
                       d.INTERFACE_ID,
                       d.STAGE_NUMBER
                  FROM AD_INT_DEPENDENCIES d
                  JOIN AD_MSG_AUDIT        prereq
                    ON  prereq.INTERFACE_ID  = d.DEPENDS_ON_INTERFACE_ID
                   AND  prereq.STAGE_NUMBER  = d.DEPENDS_ON_STAGE_NUMBER
                   AND  prereq.STATUS       NOT IN ('PROCESSED', 'ERROR')
                 WHERE d.STATUS = 'A'
            )
            SELECT a.ROWID AS row_id
              FROM AD_MSG_AUDIT  a
              JOIN AD_INT_MASTER m
                ON  m.INTERFACE_ID     = a.INTERFACE_ID
               AND  m.STAGE_NUMBER     = a.STAGE_NUMBER
               AND  m.DISPATCH_TYPE    = 'ATP_GROUP'
               AND  m.EXECUTION_TYPE   = 'P'
               AND  m.STATUS           = 'A'
               AND  m.OUTAGE           = 'N'
               AND  (m.WAITING_TIME = 0 OR
                     TRUNC((SYSDATE - a.LAST_UPDATE_DATE) * 24 * 60 * 60)
                     >= m.WAITING_TIME)
               AND  (   m.DISPATCH_FREQUENCY IS NULL
                     OR F_NEXT_DISPATCH_DATE(m.DISPATCH_FREQUENCY, m.LAST_DISPATCHED_DATE) <= SYSDATE)
              LEFT JOIN blocked_keys bk
                ON  bk.INTERFACE_ID         = a.INTERFACE_ID
               AND  bk.STAGE_NUMBER         = a.STAGE_NUMBER
             WHERE a.STATUS IN ('QUEUED', 'RETRY')
               AND bk.INTERFACE_ID IS NULL   -- dependency gate: not blocked
        ) src
        ON (tgt.ROWID = src.row_id)
        WHEN MATCHED THEN
            UPDATE SET tgt.STATUS           = 'READY_TO_DISPATCH',
                       tgt.LAST_UPDATE_DATE = SYSDATE;

        -- ══════════════════════════════════════════════════════════════════════
        -- PART B2: ATP_GROUP SERIAL — single MERGE, set-based minimum derivation
        -- Minimum eligible sequence per (INTERFACE_ID, STAGE_NUMBER) computed
        -- inline. PARENT_MSG_SEQUENCE used when present, MSG_SEQUENCE otherwise.
        -- Blocking considers all statuses (QUEUED, RETRY, PROCESSING).
        -- Dependency gate: blocked_keys CTE excludes rows whose prerequisite
        -- interface still has non-terminal messages (global blocking).
        -- ══════════════════════════════════════════════════════════════════════
        MERGE /*+ enable_parallel_dml parallel(4) */
         INTO AD_MSG_AUDIT tgt
        USING
        (
            WITH blocked_keys AS
            (
                SELECT DISTINCT
                       d.INTERFACE_ID,
                       d.STAGE_NUMBER
                  FROM AD_INT_DEPENDENCIES d
                  JOIN AD_MSG_AUDIT        prereq
                    ON  prereq.INTERFACE_ID  = d.DEPENDS_ON_INTERFACE_ID
                   AND  prereq.STAGE_NUMBER  = d.DEPENDS_ON_STAGE_NUMBER
                   AND  prereq.STATUS       NOT IN ('PROCESSED', 'ERROR')
                 WHERE d.STATUS = 'A'
            )
            SELECT a.ROWID AS row_id
              FROM AD_MSG_AUDIT  a
              JOIN AD_INT_MASTER m
                ON  m.INTERFACE_ID   = a.INTERFACE_ID
               AND  m.STAGE_NUMBER   = a.STAGE_NUMBER
               AND  m.DISPATCH_TYPE  = 'ATP_GROUP'
               AND  m.EXECUTION_TYPE = 'S'
               AND  m.STATUS         = 'A'
               AND  m.OUTAGE         = 'N'
               AND  (m.WAITING_TIME = 0 OR
                     TRUNC((SYSDATE - a.LAST_UPDATE_DATE) * 24 * 60 * 60)
                     >= m.WAITING_TIME)
               AND  (   m.DISPATCH_FREQUENCY IS NULL
                     OR F_NEXT_DISPATCH_DATE(m.DISPATCH_FREQUENCY, m.LAST_DISPATCHED_DATE) <= SYSDATE)
              JOIN
              (
                  -- Minimum sequence per interface — includes READY_TO_DISPATCH
                  -- so a group already queued for dispatch blocks higher sequences
                  SELECT b.INTERFACE_ID,
                         b.STAGE_NUMBER,
                         MIN(b.PARENT_MSG_SEQUENCE) AS min_seq,
                         'Y'                        AS use_parent
                    FROM AD_MSG_AUDIT  b
                    JOIN AD_INT_MASTER n
                      ON  n.INTERFACE_ID   = b.INTERFACE_ID
                     AND  n.STAGE_NUMBER   = b.STAGE_NUMBER
                     AND  n.DISPATCH_TYPE  = 'ATP_GROUP'
                     AND  n.EXECUTION_TYPE = 'S'
                     AND  n.STATUS         = 'A'
                   WHERE b.STATUS IN ('QUEUED', 'RETRY', 'PROCESSING', 'READY_TO_DISPATCH')
                     AND b.PARENT_MSG_SEQUENCE IS NOT NULL
                   GROUP BY b.INTERFACE_ID, b.STAGE_NUMBER

                  UNION ALL

                  SELECT b.INTERFACE_ID,
                         b.STAGE_NUMBER,
                         MIN(b.MSG_SEQUENCE) AS min_seq,
                         'N'                 AS use_parent
                    FROM AD_MSG_AUDIT  b
                    JOIN AD_INT_MASTER n
                      ON  n.INTERFACE_ID   = b.INTERFACE_ID
                     AND  n.STAGE_NUMBER   = b.STAGE_NUMBER
                     AND  n.DISPATCH_TYPE  = 'ATP_GROUP'
                     AND  n.EXECUTION_TYPE = 'S'
                     AND  n.STATUS         = 'A'
                   WHERE b.STATUS IN ('QUEUED', 'RETRY', 'PROCESSING', 'READY_TO_DISPATCH')
                     AND b.PARENT_MSG_SEQUENCE IS NULL
                   GROUP BY b.INTERFACE_ID, b.STAGE_NUMBER
              ) mins
                ON  mins.INTERFACE_ID = a.INTERFACE_ID
               AND  mins.STAGE_NUMBER = a.STAGE_NUMBER
               AND  a.STATUS IN ('QUEUED', 'RETRY')
               AND  (
                        (mins.use_parent = 'Y'
                         AND a.PARENT_MSG_SEQUENCE = mins.min_seq)
                     OR (mins.use_parent = 'N'
                         AND a.PARENT_MSG_SEQUENCE IS NULL
                         AND a.MSG_SEQUENCE = mins.min_seq)
                    )
              LEFT JOIN blocked_keys bk
                ON  bk.INTERFACE_ID         = a.INTERFACE_ID
               AND  bk.STAGE_NUMBER         = a.STAGE_NUMBER
             WHERE bk.INTERFACE_ID IS NULL   -- dependency gate: not blocked
        ) src
        ON (tgt.ROWID = src.row_id)
        WHEN MATCHED THEN
            UPDATE SET tgt.STATUS           = 'READY_TO_DISPATCH',
                       tgt.LAST_UPDATE_DATE = SYSDATE;

        COMMIT;

        DBMS_OUTPUT.PUT_LINE('SEQUENCE_MSGS completed ' || SYSTIMESTAMP);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.SEQUENCE_MSGS',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM
            );
            DBMS_OUTPUT.PUT_LINE('SEQUENCE_MSGS fatal: ' || SQLERRM);
            RAISE;
    END SEQUENCE_MSGS;


    -- =========================================================================
    -- REMOVE_DUPLICATES  (private)
    -- Deletes duplicate QUEUED/RETRY rows for ATP_INDIVIDUAL interfaces,
    -- keeping only the lowest MSG_ID per
    -- (INTERFACE_ID, STAGE_NUMBER, BUSINESS_IDENTIFIER1).
    -- Called by DISPATCH before SEQUENCE_MSGS.
    -- =========================================================================
    PROCEDURE REMOVE_DUPLICATES
    IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('REMOVE_DUPLICATES started ' || SYSTIMESTAMP);

        DELETE FROM AD_MSG_AUDIT
         WHERE MSG_ID IN
               (
                   SELECT MSG_ID
                     FROM
                     (
                         SELECT a.MSG_ID,
                                ROW_NUMBER() OVER
                                (
                                    PARTITION BY a.INTERFACE_ID,
                                                 a.STAGE_NUMBER,
                                                 a.BUSINESS_IDENTIFIER1
                                    ORDER BY a.MSG_ID
                                ) AS rn
                           FROM AD_MSG_AUDIT  a
                           JOIN AD_INT_MASTER m
                             ON  m.INTERFACE_ID  = a.INTERFACE_ID
                            AND  m.STAGE_NUMBER  = a.STAGE_NUMBER
                            AND  m.DISPATCH_TYPE = 'ATP_INDIVIDUAL'
                            AND  m.STATUS        = 'A'
                          WHERE a.STATUS IN ('QUEUED', 'RETRY')
                     )
                    WHERE rn > 1
               );

        DBMS_OUTPUT.PUT_LINE('REMOVE_DUPLICATES deleted ' || SQL%ROWCOUNT || ' rows ' || SYSTIMESTAMP);
        COMMIT;

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.REMOVE_DUPLICATES',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM
            );
            DBMS_OUTPUT.PUT_LINE('REMOVE_DUPLICATES fatal: ' || SQLERRM);
            RAISE;
    END REMOVE_DUPLICATES;


    -- =========================================================================
    -- DISPATCH  (public — no parameters)
    -- Single entry point. Routes each interface to individual or group logic.
    -- =========================================================================
    PROCEDURE DISPATCH
    IS
        l_envs       t_env_tab;
        l_env_count  PLS_INTEGER := 0;
        l_intfs      t_intf_tab;
        l_intf_count PLS_INTEGER := 0;
        l_run_id     VARCHAR2(30);
        l_global_worker NUMBER := 0;

    BEGIN

        DBMS_OUTPUT.PUT_LINE('DISPATCH started ' || SYSTIMESTAMP);

        -- ── Step 0a: Remove duplicates — keep lowest MSG_ID per business key ────
        REMOVE_DUPLICATES;

        -- ── Step 0b: Sequence msgs — promote QUEUED/RETRY to READY_TO_DISPATCH ──
        SEQUENCE_MSGS;

        -- ── Step 1: Discover interfaces with pending msgs ─────────────────────
        -- Done first: if nothing is pending we exit before any OIC API calls.
        FOR r IN
        (
            SELECT DISTINCT
                   m.INTERFACE_ID,
                   m.STAGE_NUMBER,
                   m.PRIORITY,
                   m.DISPATCH_TYPE,
                   m.MAX_MSGS
              FROM AD_MSG_AUDIT  a
              JOIN AD_INT_MASTER m
                ON  m.INTERFACE_ID = a.INTERFACE_ID
               AND  m.STAGE_NUMBER = a.STAGE_NUMBER
             WHERE a.STATUS         = 'READY_TO_DISPATCH'
               AND m.STATUS         = 'A'
               AND m.OUTAGE         = 'N'
               AND m.DISPATCH_TYPE  IN ('ATP_INDIVIDUAL', 'ATP_GROUP')
               AND (   m.DISPATCH_FREQUENCY IS NULL
                    OR F_NEXT_DISPATCH_DATE(m.DISPATCH_FREQUENCY, m.LAST_DISPATCHED_DATE) <= SYSDATE)
             ORDER BY m.PRIORITY, m.INTERFACE_ID, m.STAGE_NUMBER
        )
        LOOP
            l_intf_count := l_intf_count + 1;
            l_intfs(l_intf_count).interface_id  := r.INTERFACE_ID;
            l_intfs(l_intf_count).stage_number  := r.STAGE_NUMBER;
            l_intfs(l_intf_count).priority      := r.PRIORITY;
            l_intfs(l_intf_count).dispatch_type := r.DISPATCH_TYPE;
            l_intfs(l_intf_count).max_msgs      := r.MAX_MSGS;
        END LOOP;

        IF l_intf_count = 0 THEN
            DBMS_OUTPUT.PUT_LINE('No interfaces with pending messages. Exiting.');
            RETURN;
        END IF;

        DBMS_OUTPUT.PUT_LINE('Interfaces to process: ' || l_intf_count);

        -- ── Step 2: Load all active environments ──────────────────────────────
        FOR r IN
        (
            SELECT e.ENV_ID,
                   e.BASE_URL,
                   e.MAX_MSGS
              FROM AD_OIC_ENVIRONMENTS e
             WHERE e.STATUS = 'A'
             ORDER BY e.ENV_ID
        )
        LOOP
            l_env_count := l_env_count + 1;
            l_envs(l_env_count).env_id          := r.ENV_ID;
            l_envs(l_env_count).base_url         := r.BASE_URL;
            l_envs(l_env_count).max_msgs         := r.MAX_MSGS;
            l_envs(l_env_count).running_count    := 0;
            l_envs(l_env_count).fallback         := 'N';
        END LOOP;

        IF l_env_count = 0 THEN
            DBMS_OUTPUT.PUT_LINE('No active environments. Exiting.');
            RETURN;
        END IF;

        -- Generate run ID before spawning any jobs
        SELECT TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF3')
          INTO l_run_id
          FROM DUAL;

        -- ── Step 3: Fetch live running instance counts (async, 5s timeout) ──────
        -- For each env: set LAST_RUNNING_COUNT = NULL, spawn a scheduler job
        -- that calls GET_RUNNING_INSTANCES and writes the result back.
        -- Poll every 0.5s up to 5 seconds. Envs that don't respond in time
        -- are treated as -1 (static fallback). The scheduler jobs continue
        -- running in the background but DISPATCH has already moved on.
        DBMS_OUTPUT.PUT_LINE('Fetching running instance counts (3s timeout)...');

        -- Clear previous counts so polling can detect fresh writes
        UPDATE AD_OIC_ENVIRONMENTS
           SET LAST_RUNNING_COUNT = NULL
         WHERE STATUS = 'A';
        COMMIT;

        -- Spawn one scheduler job per env
        FOR i IN 1 .. l_env_count LOOP
            DECLARE
                l_job_name VARCHAR2(128);
            BEGIN
                l_job_name := SUBSTR('AD_GET_INST_' || l_run_id || '_' || i, 1, 128);

                DBMS_SCHEDULER.CREATE_JOB
                (
                    job_name   => l_job_name,
                    job_type   => 'PLSQL_BLOCK',
                    job_action => 'BEGIN AD_PARKING_LOT_PKG.GET_RUNNING_INSTANCES('''
                                  || l_envs(i).env_id || '''); END;',
                    start_date => SYSTIMESTAMP,
                    enabled    => TRUE,
                    auto_drop  => TRUE
                );
            EXCEPTION
                WHEN OTHERS THEN
                    DBMS_OUTPUT.PUT_LINE
                    (
                        'Failed to spawn GET_RUNNING_INSTANCES job for ['
                        || l_envs(i).env_id || ']: ' || SQLERRM
                    );
            END;
        END LOOP;

        -- Poll every 0.5s up to 5 seconds (10 iterations)
        FOR poll IN 1 .. 10 LOOP
            DBMS_SESSION.SLEEP(0.5);

            -- Check if all envs have a result
            DECLARE
                l_pending NUMBER;
            BEGIN
                SELECT COUNT(*)
                  INTO l_pending
                  FROM AD_OIC_ENVIRONMENTS
                 WHERE STATUS              = 'A'
                   AND LAST_RUNNING_COUNT IS NULL;

                EXIT WHEN l_pending = 0; -- all envs responded
            END;
        END LOOP;

        -- Read results — NULL after timeout treated as -1
        FOR i IN 1 .. l_env_count LOOP
            SELECT NVL(LAST_RUNNING_COUNT, -1)
              INTO l_envs(i).running_count
              FROM AD_OIC_ENVIRONMENTS
             WHERE ENV_ID = l_envs(i).env_id;

            -- available_cap = MAX_MSGS per run (NULL = unlimited sentinel)
            l_envs(i).available_cap := NVL(l_envs(i).max_msgs, 2147483647);

            DBMS_OUTPUT.PUT_LINE
            (
                'ENV [' || l_envs(i).env_id
                || '] running=' || CASE
                                       WHEN l_envs(i).running_count = -1
                                       THEN 'API failed/timeout'
                                       ELSE TO_CHAR(l_envs(i).running_count)
                                   END
                || ' cap=' || NVL(TO_CHAR(l_envs(i).max_msgs), 'unlimited')
            );

            -- Fetch / refresh Bearer token for this env
            l_envs(i).bearer_token := f_get_bearer_token(l_envs(i).env_id);
            IF l_envs(i).bearer_token IS NOT NULL THEN
                DBMS_OUTPUT.PUT_LINE
                (
                    'ENV [' || l_envs(i).env_id || '] bearer token ready'
                );
            ELSE
                DBMS_OUTPUT.PUT_LINE
                (
                    'ENV [' || l_envs(i).env_id
                    || '] bearer token unavailable — will retry per chunk'
                );
            END IF;
        END LOOP;

        -- ── Unique run ID shared across all interfaces ─────────────────────────


        -- ── Step 4: Process each interface ────────────────────────────────────
        FOR intf IN 1 .. l_intf_count LOOP

            DBMS_OUTPUT.PUT_LINE
            (
                'Interface [' || l_intfs(intf).interface_id
                || '] stage='  || l_intfs(intf).stage_number
                || ' type='    || l_intfs(intf).dispatch_type
            );

            -- Validate allocation sums to 100
            IF NOT f_validate_allocation
                   (
                       l_intfs(intf).interface_id,
                       l_intfs(intf).stage_number
                   )
            THEN
                DBMS_OUTPUT.PUT_LINE
                (
                    '  Allocation <> 100% — skipping.'
                );
                CONTINUE;
            END IF;

            -- Route by DISPATCH_TYPE
            IF l_intfs(intf).dispatch_type = 'ATP_INDIVIDUAL' THEN

                p_dispatch_individual_intf
                (
                    p_envs          => l_envs,
                    p_env_count     => l_env_count,
                    p_interface_id  => l_intfs(intf).interface_id,
                    p_stage_number  => l_intfs(intf).stage_number,
                    p_interface_cap => l_intfs(intf).max_msgs,
                    p_run_id        => l_run_id,
                    p_global_worker => l_global_worker
                );

                -- Advance LAST_DISPATCHED_DATE immediately after dispatch
                UPDATE AD_INT_MASTER
                   SET LAST_DISPATCHED_DATE = SYSDATE
                 WHERE INTERFACE_ID = l_intfs(intf).interface_id
                   AND STAGE_NUMBER = l_intfs(intf).stage_number;
                COMMIT;

            ELSIF l_intfs(intf).dispatch_type = 'ATP_GROUP' THEN

                p_dispatch_group_intf
                (
                    p_envs          => l_envs,
                    p_env_count     => l_env_count,
                    p_interface_id  => l_intfs(intf).interface_id,
                    p_stage_number  => l_intfs(intf).stage_number,
                    p_interface_cap => l_intfs(intf).max_msgs,
                    p_run_id        => l_run_id,
                    p_global_worker => l_global_worker
                );

                -- Advance LAST_DISPATCHED_DATE immediately after dispatch
                UPDATE AD_INT_MASTER
                   SET LAST_DISPATCHED_DATE = SYSDATE
                 WHERE INTERFACE_ID = l_intfs(intf).interface_id
                   AND STAGE_NUMBER = l_intfs(intf).stage_number;
                COMMIT;

            ELSE
                DBMS_OUTPUT.PUT_LINE
                (
                    '  Unknown DISPATCH_TYPE: '
                    || l_intfs(intf).dispatch_type || ' — skipping.'
                );
            END IF;

        END LOOP;

        DBMS_OUTPUT.PUT_LINE('DISPATCH completed ' || SYSTIMESTAMP);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.DISPATCH',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM
            );
            DBMS_OUTPUT.PUT_LINE('DISPATCH fatal: ' || SQLERRM);
            RAISE;
    END DISPATCH;


    -- =========================================================================
    -- DISPATCH_INDIVIDUAL_CHUNK  (public)
    -- Called by scheduler job for ATP_INDIVIDUAL.
    -- Sends messages as a JSON array to OIC. Array size is controlled by
    -- AD_INT_MASTER.INDIVIDUAL_BATCH_SIZE (NULL treated as 1).
    -- HTTP 202 = success, rows stay PROCESSING.
    -- OIC integration updates STATUS when done.
    -- =========================================================================
    PROCEDURE DISPATCH_INDIVIDUAL_CHUNK
    (
        p_chunk_id IN VARCHAR2
    )
    IS
        TYPE t_msg_rec IS RECORD
        (
            msg_id               AD_MSG_AUDIT.MSG_ID%TYPE,
            msg_object_id        AD_MSG_AUDIT.MSG_OBJECT_ID%TYPE,
            interface_id         AD_MSG_AUDIT.INTERFACE_ID%TYPE,
            business_identifier1 AD_MSG_AUDIT.BUSINESS_IDENTIFIER1%TYPE,
            business_identifier2 AD_MSG_AUDIT.BUSINESS_IDENTIFIER2%TYPE,
            business_identifier3 AD_MSG_AUDIT.BUSINESS_IDENTIFIER3%TYPE,
            business_identifier4 AD_MSG_AUDIT.BUSINESS_IDENTIFIER4%TYPE,
            business_identifier5 AD_MSG_AUDIT.BUSINESS_IDENTIFIER5%TYPE,
            retry_count          AD_MSG_AUDIT.RETRY_COUNT%TYPE,
            max_retry_count      AD_INT_MASTER.MAX_RETRY_COUNT%TYPE,
            retry_enabled        AD_INT_MASTER.RETRY_ENABLED%TYPE,
            oic_resource         AD_INT_MASTER.OIC_PROCESSOR_INTEGRATION_URI%TYPE,
            individual_batch_size AD_INT_MASTER.INDIVIDUAL_BATCH_SIZE%TYPE
        );
        TYPE t_msg_tab    IS TABLE OF t_msg_rec;
        TYPE t_error_tab  IS TABLE OF VARCHAR2(30000);
        TYPE t_status_tab IS TABLE OF VARCHAR2(50);
        TYPE t_num_tab    IS TABLE OF NUMBER;

        l_msgs        t_msg_tab;
        l_errors      t_error_tab  := t_error_tab();
        l_statuses    t_status_tab := t_status_tab();
        l_msg_ids     t_num_tab    := t_num_tab();

        l_env_id       AD_OIC_ENVIRONMENTS.ENV_ID%TYPE;
        l_base_url     AD_OIC_ENVIRONMENTS.BASE_URL%TYPE;
        l_bearer_token VARCHAR2(4000);
        l_body         CLOB;
        l_response     DBMS_CLOUD_TYPES.RESP;
        l_batch_size   PLS_INTEGER;
        l_batch_start  PLS_INTEGER;
        l_batch_end    PLS_INTEGER;
        l_batch_err    VARCHAR2(30000);
        l_batch_status VARCHAR2(50);

    BEGIN

        DBMS_OUTPUT.PUT_LINE
        (
            'DISPATCH_INDIVIDUAL_CHUNK [' || p_chunk_id || '] started ' || SYSTIMESTAMP
        );

        l_env_id := f_env_from_chunk(p_chunk_id);

        BEGIN
            SELECT BASE_URL
              INTO l_base_url
              FROM AD_OIC_ENVIRONMENTS
             WHERE ENV_ID = l_env_id AND STATUS = 'A';
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                UPDATE AD_MSG_AUDIT
                   SET STATUS           = 'ERROR',
                       ERROR_MESSAGE    = 'Environment not found or inactive: ' || l_env_id,
                       LAST_UPDATE_DATE = SYSDATE
                 WHERE CHUNK_ID = p_chunk_id AND STATUS = 'PROCESSING';
                COMMIT;
                RETURN;
        END;

        SELECT a.MSG_ID,
               a.MSG_OBJECT_ID,
               a.INTERFACE_ID,
               a.BUSINESS_IDENTIFIER1,
               a.BUSINESS_IDENTIFIER2,
               a.BUSINESS_IDENTIFIER3,
               a.BUSINESS_IDENTIFIER4,
               a.BUSINESS_IDENTIFIER5,
               a.RETRY_COUNT,
               m.MAX_RETRY_COUNT,
               m.RETRY_ENABLED,
               m.OIC_PROCESSOR_INTEGRATION_URI,
               m.INDIVIDUAL_BATCH_SIZE
          BULK COLLECT INTO l_msgs
          FROM AD_MSG_AUDIT  a
          JOIN AD_INT_MASTER m
            ON  m.INTERFACE_ID = a.INTERFACE_ID
           AND  m.STAGE_NUMBER = a.STAGE_NUMBER
           AND  m.STATUS       = 'A'
         WHERE a.CHUNK_ID = p_chunk_id
           AND a.STATUS   = 'PROCESSING';

        IF l_msgs.COUNT = 0 THEN RETURN; END IF;

        -- Get Bearer token (cached or fresh — never basic auth)
        l_bearer_token := f_get_bearer_token(l_env_id);

        l_errors  .EXTEND(l_msgs.COUNT);
        l_statuses.EXTEND(l_msgs.COUNT);
        l_msg_ids .EXTEND(l_msgs.COUNT);

        -- Populate msg_ids array (needed for FORALL update at the end)
        FOR i IN 1 .. l_msgs.COUNT LOOP
            l_msg_ids(i) := l_msgs(i).msg_id;
        END LOOP;

        -- Batch size: NULL treated as 1 (one message per OIC call)
        l_batch_size := NVL(l_msgs(1).individual_batch_size, 1);
        IF l_batch_size < 1 THEN l_batch_size := 1; END IF;

        -- HTTP loop — processes messages in batches of l_batch_size
        -- Each batch is sent as a JSON array in a single OIC invocation.
        -- All messages in a batch share the same success/failure outcome.
        l_batch_start := 1;
        WHILE l_batch_start <= l_msgs.COUNT LOOP

            l_batch_end := LEAST(l_batch_start + l_batch_size - 1, l_msgs.COUNT);
            l_batch_err    := NULL;
            l_batch_status := NULL;

            BEGIN
                -- Build JSON array for this batch
                l_body := '[';
                FOR i IN l_batch_start .. l_batch_end LOOP
                    IF i > l_batch_start THEN
                        l_body := l_body || ',';
                    END IF;
                    l_body := l_body || JSON_OBJECT(
                                   'MsgId'               VALUE l_msgs(i).msg_id,
                                   'MsgObjectId'         VALUE l_msgs(i).msg_object_id,
                                   'InterfaceId'         VALUE l_msgs(i).interface_id,
                                   'BusinessIdentifier1' VALUE l_msgs(i).business_identifier1,
                                   'BusinessIdentifier2' VALUE l_msgs(i).business_identifier2,
                                   'BusinessIdentifier3' VALUE l_msgs(i).business_identifier3,
                                   'BusinessIdentifier4' VALUE l_msgs(i).business_identifier4,
                                   'BusinessIdentifier5' VALUE l_msgs(i).business_identifier5
                               );
                END LOOP;
                l_body := l_body || ']';

                IF l_bearer_token IS NOT NULL THEN
                    l_response := DBMS_CLOUD.SEND_REQUEST
                    (
                        credential_name => NULL,
                        uri             => l_base_url || l_msgs(l_batch_start).oic_resource,
                        method          => DBMS_CLOUD.METHOD_POST,
                        body            => UTL_RAW.CAST_TO_RAW(l_body),
                        headers         => JSON_OBJECT
                                           (
                                               'Content-Type'  VALUE 'application/json',
                                               'Authorization' VALUE 'Bearer ' || l_bearer_token
                                           )
                    );
                    -- 401 — refresh token and retry once
                    IF l_response.status_code = 401 THEN
                        DBMS_OUTPUT.PUT_LINE
                        (
                            'DISPATCH_INDIVIDUAL_CHUNK: 401 for env ['
                            || l_env_id || '] — refreshing token and retrying'
                        );
                        l_bearer_token := f_get_bearer_token
                                          (
                                              p_env_id      => l_env_id,
                                              p_force_fresh => TRUE
                                          );
                        IF l_bearer_token IS NOT NULL THEN
                            l_response := DBMS_CLOUD.SEND_REQUEST
                            (
                                credential_name => NULL,
                                uri             => l_base_url || l_msgs(l_batch_start).oic_resource,
                                method          => DBMS_CLOUD.METHOD_POST,
                                body            => UTL_RAW.CAST_TO_RAW(l_body),
                                headers         => JSON_OBJECT
                                                   (
                                                       'Content-Type'  VALUE 'application/json',
                                                       'Authorization' VALUE 'Bearer ' || l_bearer_token
                                                   )
                            );
                        END IF;
                    END IF;

                    IF l_response.status_code = 202 THEN
                        -- Success: leave rows as PROCESSING.
                        -- OIC integration will update STATUS when processing completes.
                        l_batch_err    := NULL;
                        l_batch_status := NULL;
                    ELSE
                        l_batch_err    := 'HTTP ' || l_response.status_code
                                          || ' for batch starting msgId=' || l_msgs(l_batch_start).msg_id;
                        l_batch_status := NULL; -- resolved per-message below
                    END IF;
                ELSE
                    -- No Bearer token — cannot dispatch without OAuth
                    DBMS_OUTPUT.PUT_LINE
                    (
                        'DISPATCH_INDIVIDUAL_CHUNK: no Bearer token for env ['
                        || l_env_id || '] — batch starting msg '
                        || l_msgs(l_batch_start).msg_id || ' will ERROR'
                    );
                    l_batch_err    := 'No Bearer token available for env ' || l_env_id;
                    l_batch_status := NULL; -- resolved per-message below
                END IF;

            EXCEPTION
                WHEN OTHERS THEN
                    l_batch_err    := SUBSTR(SQLERRM, 1, 30000);
                    l_batch_status := NULL;
            END;

            -- Propagate batch outcome to every message in the batch
            FOR i IN l_batch_start .. l_batch_end LOOP
                IF l_batch_err IS NULL THEN
                    l_errors  (i) := NULL;
                    l_statuses(i) := NULL;
                ELSE
                    l_errors  (i) := l_batch_err;
                    l_statuses(i) := CASE
                        WHEN l_msgs(i).retry_enabled = 'Y'
                         AND l_msgs(i).retry_count   < l_msgs(i).max_retry_count
                        THEN 'RETRY' ELSE 'ERROR' END;
                END IF;
            END LOOP;

            l_batch_start := l_batch_end + 1;

        END LOOP;

        -- Update failed rows only
        FORALL i IN 1 .. l_msgs.COUNT
            UPDATE AD_MSG_AUDIT
               SET STATUS           = l_statuses(i),
                   ERROR_MESSAGE    = l_errors(i),
                   RETRY_COUNT      = NVL(RETRY_COUNT, 0)
                                      + CASE WHEN l_errors(i) IS NOT NULL THEN 1 ELSE 0 END,
                   LAST_UPDATE_DATE = SYSDATE
             WHERE MSG_ID        = l_msg_ids(i)
               AND l_errors(i) IS NOT NULL;

        COMMIT;

        DBMS_OUTPUT.PUT_LINE
        (
            'DISPATCH_INDIVIDUAL_CHUNK [' || p_chunk_id || '] finished ' || SYSTIMESTAMP
        );

    EXCEPTION
        WHEN OTHERS THEN
            DECLARE
                l_fatal_err VARCHAR2(30000) := SUBSTR(SQLERRM, 1, 30000);
            BEGIN
                ROLLBACK;
                p_log_error
                (
                    p_procedure_name => 'AD_PARKING_LOT_PKG.DISPATCH_INDIVIDUAL_CHUNK',
                    p_error_code     => SQLCODE,
                    p_error_message  => SQLERRM,
                    p_notes          => 'chunk_id=' || p_chunk_id
                );
                DBMS_OUTPUT.PUT_LINE
                (
                    'DISPATCH_INDIVIDUAL_CHUNK fatal [' || p_chunk_id || ']: ' || l_fatal_err
                );
                UPDATE AD_MSG_AUDIT
                   SET STATUS           = 'ERROR',
                       ERROR_MESSAGE    = SUBSTR('Chunk fatal: ' || l_fatal_err, 1, 30000),
                       RETRY_COUNT      = NVL(RETRY_COUNT, 0) + 1,
                       LAST_UPDATE_DATE = SYSDATE
                 WHERE CHUNK_ID = p_chunk_id AND STATUS = 'PROCESSING';
                COMMIT;
                RAISE;
            END;
    END DISPATCH_INDIVIDUAL_CHUNK;


    -- =========================================================================
    -- DISPATCH_GROUP_CHUNK  (public)
    -- Called by scheduler job for ATP_GROUP.
    -- One chunk = one group = one (MSG_SEQUENCE, INTERFACE_ID, STAGE_NUMBER).
    -- Payload: { "msgSequence": N, "interfaceId": "X",
    --            "subGroupId": N, "stageNumber": N }
    -- HTTP 202 = success, all rows in group stay PROCESSING.
    -- OIC integration updates STATUS when done.
    -- =========================================================================
    PROCEDURE DISPATCH_GROUP_CHUNK
    (
        p_chunk_id IN VARCHAR2
    )
    IS
        -- One representative row for the group (all share same sequence/interface)
        TYPE t_grp_rec IS RECORD
        (
            msg_id          AD_MSG_AUDIT.MSG_ID%TYPE,
            msg_sequence    AD_MSG_AUDIT.MSG_SEQUENCE%TYPE,
            interface_id    AD_MSG_AUDIT.INTERFACE_ID%TYPE,
            stage_number    AD_MSG_AUDIT.STAGE_NUMBER%TYPE,
            sub_group_id    AD_MSG_AUDIT.MSG_SUB_GROUP_ID%TYPE,
            retry_count     AD_MSG_AUDIT.RETRY_COUNT%TYPE,
            max_retry_count AD_INT_MASTER.MAX_RETRY_COUNT%TYPE,
            retry_enabled   AD_INT_MASTER.RETRY_ENABLED%TYPE,
            oic_resource    AD_INT_MASTER.OIC_PROCESSOR_INTEGRATION_URI%TYPE
        );
        TYPE t_grp_tab IS TABLE OF t_grp_rec;

        l_rows        t_grp_tab;
        l_env_id       AD_OIC_ENVIRONMENTS.ENV_ID%TYPE;
        l_base_url     AD_OIC_ENVIRONMENTS.BASE_URL%TYPE;
        l_bearer_token VARCHAR2(4000);
        l_body         CLOB;
        l_response     DBMS_CLOUD_TYPES.RESP;
        l_new_status  VARCHAR2(50);
        l_err_msg     VARCHAR2(30000);

    BEGIN

        DBMS_OUTPUT.PUT_LINE
        (
            'DISPATCH_GROUP_CHUNK [' || p_chunk_id || '] started ' || SYSTIMESTAMP
        );

        l_env_id := f_env_from_chunk(p_chunk_id);

        BEGIN
            SELECT BASE_URL
              INTO l_base_url
              FROM AD_OIC_ENVIRONMENTS
             WHERE ENV_ID = l_env_id AND STATUS = 'A';
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                UPDATE AD_MSG_AUDIT
                   SET STATUS           = 'ERROR',
                       ERROR_MESSAGE    = 'Environment not found or inactive: ' || l_env_id,
                       LAST_UPDATE_DATE = SYSDATE
                 WHERE CHUNK_ID = p_chunk_id AND STATUS = 'PROCESSING';
                COMMIT;
                RETURN;
        END;

        -- Get cached Bearer token
        l_bearer_token := f_get_bearer_token(l_env_id);

        -- Fetch all msgs for this group chunk (shared CHUNK_ID)
        SELECT a.MSG_ID,
               a.MSG_SEQUENCE,
               a.INTERFACE_ID,
               a.STAGE_NUMBER,
               a.MSG_SUB_GROUP_ID,
               a.RETRY_COUNT,
               m.MAX_RETRY_COUNT,
               m.RETRY_ENABLED,
               m.OIC_PROCESSOR_INTEGRATION_URI
          BULK COLLECT INTO l_rows
          FROM AD_MSG_AUDIT  a
          JOIN AD_INT_MASTER m
            ON  m.INTERFACE_ID = a.INTERFACE_ID
           AND  m.STAGE_NUMBER = a.STAGE_NUMBER
           AND  m.STATUS       = 'A'
         WHERE a.CHUNK_ID = p_chunk_id
           AND a.STATUS   = 'PROCESSING';

        IF l_rows.COUNT = 0 THEN RETURN; END IF;

        -- All rows in the group share the same sequence/interface/stage/subgroup
        -- Use first row to build the payload
        BEGIN
            l_body := JSON_OBJECT
            (
                'msgSequence' VALUE l_rows(1).msg_sequence,
                'interfaceId' VALUE l_rows(1).interface_id,
                'subGroupId'  VALUE l_rows(1).sub_group_id,
                'stageNumber' VALUE l_rows(1).stage_number
            );

            -- Use Bearer token if available, otherwise fall back to credential
            IF l_bearer_token IS NOT NULL THEN
                l_response := DBMS_CLOUD.SEND_REQUEST
                (
                    credential_name => NULL,
                    uri             => l_base_url || l_rows(1).oic_resource,
                    method          => DBMS_CLOUD.METHOD_POST,
                    body            => UTL_RAW.CAST_TO_RAW(l_body),
                    headers         => JSON_OBJECT
                                       (
                                           'Content-Type'  VALUE 'application/json',
                                           'Authorization' VALUE 'Bearer ' || l_bearer_token
                                       )
                );

                -- 401 — refresh token and retry once
                IF l_response.status_code = 401 THEN
                    DBMS_OUTPUT.PUT_LINE
                    (
                        'DISPATCH_GROUP_CHUNK: 401 for env ['
                        || l_env_id || '] — refreshing token and retrying'
                    );
                    l_bearer_token := f_get_bearer_token
                                      (
                                          p_env_id      => l_env_id,
                                          p_force_fresh => TRUE
                                      );
                    IF l_bearer_token IS NOT NULL THEN
                        l_response := DBMS_CLOUD.SEND_REQUEST
                        (
                            credential_name => NULL,
                            uri             => l_base_url || l_rows(1).oic_resource,
                            method          => DBMS_CLOUD.METHOD_POST,
                            body            => UTL_RAW.CAST_TO_RAW(l_body),
                            headers         => JSON_OBJECT
                                               (
                                                   'Content-Type'  VALUE 'application/json',
                                                   'Authorization' VALUE 'Bearer ' || l_bearer_token
                                               )
                        );
                    END IF;
                END IF;
            ELSE
                -- No Bearer token — cannot dispatch without OAuth
                DBMS_OUTPUT.PUT_LINE
                (
                    'DISPATCH_GROUP_CHUNK: no Bearer token for env ['
                    || l_env_id || '] — chunk ' || p_chunk_id || ' will ERROR'
                );
                l_err_msg    := 'No Bearer token available for env ' || l_env_id;
                l_new_status := CASE
                    WHEN l_rows(1).retry_enabled = 'Y'
                     AND l_rows(1).retry_count   < l_rows(1).max_retry_count
                    THEN 'RETRY' ELSE 'ERROR' END;

                FORALL j IN 1 .. l_rows.COUNT
                    UPDATE AD_MSG_AUDIT
                       SET STATUS           = l_new_status,
                           ERROR_MESSAGE    = l_err_msg,
                           RETRY_COUNT      = NVL(RETRY_COUNT, 0) + CASE WHEN l_new_status = 'RETRY' THEN 1 ELSE 0 END,
                           LAST_UPDATE_DATE = SYSDATE
                     WHERE MSG_ID = l_rows(j).msg_id;
                COMMIT;
            END IF;

            IF l_response.status_code = 202 THEN
                -- Success: all msgs in group stay PROCESSING.
                -- OIC integration updates STATUS when done.
                DBMS_OUTPUT.PUT_LINE
                (
                    'DISPATCH_GROUP_CHUNK [' || p_chunk_id || '] dispatched OK'
                );
            ELSE
                -- Failure: apply retry logic to ALL msgs in the group
                l_err_msg := 'HTTP ' || l_response.status_code
                             || ' for chunk=' || p_chunk_id;

                l_new_status := CASE
                    WHEN l_rows(1).retry_enabled = 'Y'
                     AND l_rows(1).retry_count   < l_rows(1).max_retry_count
                    THEN 'RETRY' ELSE 'ERROR' END;

                UPDATE AD_MSG_AUDIT
                   SET STATUS           = l_new_status,
                       ERROR_MESSAGE    = l_err_msg,
                       RETRY_COUNT      = NVL(RETRY_COUNT, 0) + 1,
                       LAST_UPDATE_DATE = SYSDATE
                 WHERE CHUNK_ID = p_chunk_id
                   AND STATUS   = 'PROCESSING';
                COMMIT;
            END IF;

        EXCEPTION
            WHEN OTHERS THEN
                l_err_msg    := SUBSTR(SQLERRM, 1, 30000);
                l_new_status := CASE
                    WHEN l_rows(1).retry_enabled = 'Y'
                     AND l_rows(1).retry_count   < l_rows(1).max_retry_count
                    THEN 'RETRY' ELSE 'ERROR' END;

                UPDATE AD_MSG_AUDIT
                   SET STATUS           = l_new_status,
                       ERROR_MESSAGE    = l_err_msg,
                       RETRY_COUNT      = NVL(RETRY_COUNT, 0) + 1,
                       LAST_UPDATE_DATE = SYSDATE
                 WHERE CHUNK_ID = p_chunk_id
                   AND STATUS   = 'PROCESSING';
                COMMIT;
        END;

        DBMS_OUTPUT.PUT_LINE
        (
            'DISPATCH_GROUP_CHUNK [' || p_chunk_id || '] finished ' || SYSTIMESTAMP
        );

    EXCEPTION
        WHEN OTHERS THEN
            DECLARE
                l_fatal_err VARCHAR2(30000) := SUBSTR(SQLERRM, 1, 30000);
            BEGIN
                ROLLBACK;
                p_log_error
                (
                    p_procedure_name => 'AD_PARKING_LOT_PKG.DISPATCH_GROUP_CHUNK',
                    p_error_code     => SQLCODE,
                    p_error_message  => SQLERRM,
                    p_notes          => 'chunk_id=' || p_chunk_id
                );
                DBMS_OUTPUT.PUT_LINE
                (
                    'DISPATCH_GROUP_CHUNK fatal [' || p_chunk_id || ']: ' || l_fatal_err
                );
                UPDATE AD_MSG_AUDIT
                   SET STATUS           = 'ERROR',
                       ERROR_MESSAGE    = SUBSTR('Group chunk fatal: ' || l_fatal_err, 1, 30000),
                       RETRY_COUNT      = NVL(RETRY_COUNT, 0) + 1,
                       LAST_UPDATE_DATE = SYSDATE
                 WHERE CHUNK_ID = p_chunk_id AND STATUS = 'PROCESSING';
                COMMIT;
                RAISE;
            END;
    END DISPATCH_GROUP_CHUNK;




    -- =========================================================================
    -- DISPATCH_BIP  (public)
    -- Standalone BIP dispatcher — called independently from its own scheduler.
    -- Reads eligible rows from AD_SALES_ORDER_BIP_MASTER (QUEUED/RETRY),
    -- assigns CHUNK_IDs, sets RUN_STATUS = PROCESSING, then spawns one
    -- DBMS_SCHEDULER job per chunk calling DISPATCH_BIP_CHUNK.
    -- Batch size: 2 rows per chunk (matching original l_batch_size).
    -- =========================================================================
    PROCEDURE DISPATCH_BIP
    IS
        TYPE t_grp_name_tab IS TABLE OF AD_SALES_ORDER_BIP_MASTER.GROUP_NAME%TYPE;
        TYPE t_chunk_id_tab IS TABLE OF VARCHAR2(100);

        CURSOR c_pending IS
            SELECT GROUP_NAME
              FROM AD_SALES_ORDER_BIP_MASTER
             WHERE RUN_STATUS IN ('QUEUED', 'RETRY')
               AND ENABLED     = 'Y'
               AND RETRY_COUNT <= MAX_RETRY_COUNT
               AND (
                       (JOB_TYPE = 'RECURRING'
                        AND (LAST_RUN_TS IS NULL
                             OR SYSTIMESTAMP >= LAST_RUN_TS
                                + NUMTODSINTERVAL(INTERVAL_IN_SECONDS, 'SECOND')))
                    OR (JOB_TYPE = 'ONCE_OFF' AND LAST_RUN_TS IS NULL)
                   );

        l_group_names    t_grp_name_tab := t_grp_name_tab();
        l_chunk_idents   t_chunk_id_tab := t_chunk_id_tab();
        l_batch_size     CONSTANT PLS_INTEGER := 2;
        l_fetch_limit    CONSTANT PLS_INTEGER := 1000;
        l_chunk_id       VARCHAR2(100);
        l_worker_count   PLS_INTEGER;
        l_worker_num     PLS_INTEGER;
        l_chunk_ident    VARCHAR2(100);
        l_job_name       VARCHAR2(128);
        l_global_offset  PLS_INTEGER := 0;
        l_batch          t_grp_name_tab;
        l_num_attempt    NUMBER;
        l_job_submitted  VARCHAR2(1);

    BEGIN
        DBMS_OUTPUT.PUT_LINE('DISPATCH_BIP started ' || SYSTIMESTAMP);

        -- Generate unique chunk ID for this run
        SELECT TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF3')
          INTO l_chunk_id
          FROM DUAL;

        -- Fetch all eligible rows
        OPEN c_pending;
        LOOP
            FETCH c_pending BULK COLLECT INTO l_batch LIMIT l_fetch_limit;
            EXIT WHEN l_batch.COUNT = 0;

            l_group_names.EXTEND(l_batch.COUNT);
            l_chunk_idents.EXTEND(l_batch.COUNT);

            FOR i IN 1 .. l_batch.COUNT LOOP
                l_worker_num := CEIL((l_global_offset + i) / l_batch_size);
                l_group_names (l_global_offset + i) := l_batch(i);
                l_chunk_idents(l_global_offset + i) := l_chunk_id || '_' || l_worker_num;
            END LOOP;

            l_global_offset := l_global_offset + l_batch.COUNT;
            EXIT WHEN c_pending%NOTFOUND;
        END LOOP;
        CLOSE c_pending;

        IF l_global_offset = 0 THEN
            DBMS_OUTPUT.PUT_LINE('DISPATCH_BIP: nothing pending');
            RETURN;
        END IF;

        l_worker_count := CEIL(l_global_offset / l_batch_size);

        -- Mark all eligible rows as PROCESSING with their chunk ID
        FORALL i IN 1 .. l_group_names.COUNT
            UPDATE AD_SALES_ORDER_BIP_MASTER
               SET RUN_STATUS = 'PROCESSING',
                   CHUNK_ID   = l_chunk_idents(i)
             WHERE GROUP_NAME  = l_group_names(i);
        COMMIT;

        -- Spawn one scheduler job per chunk
        FOR w IN 1 .. l_worker_count LOOP
            l_chunk_ident   := l_chunk_id || '_' || w;
            l_job_name      := SUBSTR('AD_BIP_CHUNK_' || l_chunk_id || '_' || w, 1, 128);
            l_num_attempt   := 1;
            l_job_submitted := 'N';

            WHILE l_job_submitted = 'N' AND l_num_attempt <= 5 LOOP
                BEGIN
                    DBMS_SCHEDULER.CREATE_JOB
                    (
                        job_name   => l_job_name,
                        job_type   => 'PLSQL_BLOCK',
                        job_action => 'BEGIN AD_PARKING_LOT_PKG.DISPATCH_BIP_CHUNK('''
                                      || l_chunk_ident || '''); END;',
                        start_date => SYSTIMESTAMP,
                        enabled    => TRUE,
                        auto_drop  => TRUE
                    );
                    DBMS_OUTPUT.PUT_LINE('Job submitted: ' || l_job_name
                                         || ' chunk=' || l_chunk_ident);
                    l_job_submitted := 'Y';
                EXCEPTION
                    WHEN OTHERS THEN
                        DBMS_SESSION.SLEEP(l_num_attempt);
                        l_num_attempt := l_num_attempt + 1;
                        DBMS_OUTPUT.PUT_LINE('Job spawn failed (attempt '
                                             || (l_num_attempt - 1) || '): ' || SQLERRM);
                END;
            END LOOP;

            IF l_job_submitted = 'N' THEN
                DBMS_OUTPUT.PUT_LINE('DISPATCH_BIP: all attempts failed for chunk '
                                     || l_chunk_ident || ' — marking ERROR');
                UPDATE AD_SALES_ORDER_BIP_MASTER
                   SET RUN_STATUS = 'ERROR',
                       CHUNK_ID   = NULL
                 WHERE CHUNK_ID   = l_chunk_ident;
                COMMIT;
            END IF;
        END LOOP;

        DBMS_OUTPUT.PUT_LINE('DISPATCH_BIP completed ' || SYSTIMESTAMP
                             || ' — ' || l_worker_count || ' jobs spawned');

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.DISPATCH_BIP',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM
            );
            DBMS_OUTPUT.PUT_LINE('DISPATCH_BIP fatal: ' || SQLERRM);
            RAISE;
    END DISPATCH_BIP;


    -- =========================================================================
    -- DISPATCH_BIP_CHUNK  (public)
    -- Called by each DBMS_SCHEDULER job spawned by DISPATCH_BIP.
    -- Fetches rows for this chunk from AD_SALES_ORDER_BIP_MASTER,
    -- calls the OIC BIP persister integration via Bearer token (OAuth),
    -- retries once on 401. Marks rows ERROR/RETRY on failure.
    -- OIC URI read from AD_INT_MASTER for interface SalesOrderFromErp001.
    -- ENV resolved from AD_ENV_INT_MAP for interface SalesOrderFromErp001.
    -- =========================================================================
    PROCEDURE DISPATCH_BIP_CHUNK
    (
        p_chunk_id IN VARCHAR2
    )
    IS
        TYPE t_msg_rec IS RECORD
        (
            group_name          AD_SALES_ORDER_BIP_MASTER.GROUP_NAME%TYPE,
            from_date_param     VARCHAR2(50),
            to_date_param       VARCHAR2(50),
            other_parameters    AD_SALES_ORDER_BIP_MASTER.OTHER_PARAMETERS%TYPE,
            job_type            AD_SALES_ORDER_BIP_MASTER.JOB_TYPE%TYPE,
            retry_count         AD_SALES_ORDER_BIP_MASTER.RETRY_COUNT%TYPE,
            max_retry_count     AD_SALES_ORDER_BIP_MASTER.MAX_RETRY_COUNT%TYPE,
            retry_enabled       AD_INT_MASTER.RETRY_ENABLED%TYPE,
            oic_resource        AD_INT_MASTER.OIC_PROCESSOR_INTEGRATION_URI%TYPE
        );
        TYPE t_msg_tab    IS TABLE OF t_msg_rec;
        TYPE t_error_tab  IS TABLE OF VARCHAR2(4000);
        TYPE t_grp_tab    IS TABLE OF AD_SALES_ORDER_BIP_MASTER.GROUP_NAME%TYPE;

        l_msgs         t_msg_tab;
        l_errors       t_error_tab  := t_error_tab();
        l_group_names  t_grp_tab    := t_grp_tab();

        l_env_id       AD_OIC_ENVIRONMENTS.ENV_ID%TYPE;
        l_base_url     AD_OIC_ENVIRONMENTS.BASE_URL%TYPE;
        l_bearer_token VARCHAR2(4000);
        l_body         CLOB;
        l_response     DBMS_CLOUD_TYPES.RESP;

        c_interface_id CONSTANT VARCHAR2(100) := 'SalesOrderFromErp001';
        c_stage_number CONSTANT NUMBER        := 1;

    BEGIN
        DBMS_OUTPUT.PUT_LINE('DISPATCH_BIP_CHUNK [' || p_chunk_id || '] started '
                             || SYSTIMESTAMP);

        -- Resolve ENV for this interface
        BEGIN
            SELECT m.ENV_ID, e.BASE_URL
              INTO l_env_id, l_base_url
              FROM AD_ENV_INT_MAP      m
              JOIN AD_OIC_ENVIRONMENTS e ON e.ENV_ID = m.ENV_ID
             WHERE m.INTERFACE_ID  = c_interface_id
               AND m.STAGE_NUMBER  = c_stage_number
               AND m.STATUS        = 'A'
               AND e.STATUS        = 'A'
               AND ROWNUM          = 1
             ORDER BY m.ALLOCATION_PCT DESC;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                DBMS_OUTPUT.PUT_LINE('DISPATCH_BIP_CHUNK: no active env for '
                                     || c_interface_id || ' — marking ERROR');
                UPDATE AD_SALES_ORDER_BIP_MASTER
                   SET RUN_STATUS = 'ERROR'
                 WHERE CHUNK_ID   = p_chunk_id;
                COMMIT;
                RETURN;
        END;

        -- Get Bearer token
        l_bearer_token := f_get_bearer_token(l_env_id);

        -- Fetch this chunk's rows joined to AD_INT_MASTER for OIC URI + retry config
        SELECT b.GROUP_NAME,
               TO_CHAR(b.FROM_DATE_TS_PARAMETER, 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'),
               TO_CHAR(b.TO_DATE_TS_PARAMETER,   'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"'),
               b.OTHER_PARAMETERS,
               b.JOB_TYPE,
               b.RETRY_COUNT,
               b.MAX_RETRY_COUNT,
               m.RETRY_ENABLED,
               m.OIC_PROCESSOR_INTEGRATION_URI
          BULK COLLECT INTO l_msgs
          FROM AD_SALES_ORDER_BIP_MASTER b
          JOIN AD_INT_MASTER             m
            ON  m.INTERFACE_ID = c_interface_id
           AND  m.STAGE_NUMBER = c_stage_number
           AND  m.STATUS       = 'A'
         WHERE b.CHUNK_ID    = p_chunk_id
           AND b.RUN_STATUS  = 'PROCESSING';

        IF l_msgs.COUNT = 0 THEN RETURN; END IF;

        l_errors     .EXTEND(l_msgs.COUNT);
        l_group_names.EXTEND(l_msgs.COUNT);

        -- HTTP loop
        FOR i IN 1 .. l_msgs.COUNT LOOP
            l_group_names(i) := l_msgs(i).group_name;
            BEGIN
                l_body := JSON_OBJECT(
                    'Identifier'        VALUE l_msgs(i).group_name,
                    'FromDateParameter' VALUE l_msgs(i).from_date_param,
                    'ToDateParameter'   VALUE l_msgs(i).to_date_param,
                    'OtherParameters'   VALUE l_msgs(i).other_parameters,
                    'JobType'           VALUE l_msgs(i).job_type,
                    'RetryCount'        VALUE l_msgs(i).retry_count,
                    'MaxRetryCount'     VALUE l_msgs(i).max_retry_count
                );

                IF l_bearer_token IS NOT NULL THEN
                    l_response := DBMS_CLOUD.SEND_REQUEST
                    (
                        credential_name => NULL,
                        uri             => l_base_url || l_msgs(i).oic_resource,
                        method          => DBMS_CLOUD.METHOD_POST,
                        body            => UTL_RAW.CAST_TO_RAW(l_body),
                        headers         => JSON_OBJECT
                                           (
                                               'Content-Type'  VALUE 'application/json',
                                               'Authorization' VALUE 'Bearer ' || l_bearer_token
                                           )
                    );

                    -- 401 — refresh token and retry once
                    IF l_response.status_code = 401 THEN
                        DBMS_OUTPUT.PUT_LINE('DISPATCH_BIP_CHUNK: 401 — refreshing token');
                        l_bearer_token := f_get_bearer_token
                                          (
                                              p_env_id      => l_env_id,
                                              p_force_fresh => TRUE
                                          );
                        IF l_bearer_token IS NOT NULL THEN
                            l_response := DBMS_CLOUD.SEND_REQUEST
                            (
                                credential_name => NULL,
                                uri             => l_base_url || l_msgs(i).oic_resource,
                                method          => DBMS_CLOUD.METHOD_POST,
                                body            => UTL_RAW.CAST_TO_RAW(l_body),
                                headers         => JSON_OBJECT
                                                   (
                                                       'Content-Type'  VALUE 'application/json',
                                                       'Authorization' VALUE 'Bearer ' || l_bearer_token
                                                   )
                            );
                        END IF;
                    END IF;
                ELSE
                    -- No Bearer token — cannot dispatch without OAuth
                    DBMS_OUTPUT.PUT_LINE
                    (
                        'DISPATCH_BIP_CHUNK: no Bearer token for env ['
                        || l_env_id || '] — ' || l_msgs(i).group_name || ' will RETRY/ERROR'
                    );
                    l_errors(i) := 'No Bearer token available for env ' || l_env_id;
                END IF;

                -- Evaluate response if a call was made
                IF l_errors(i) IS NULL THEN
                    IF l_response.status_code = 202 THEN
                        -- Success — OIC will update RUN_STATUS when complete
                        l_errors(i) := NULL;
                    ELSE
                        l_errors(i) := 'HTTP ' || l_response.status_code
                                       || ' for ' || l_msgs(i).group_name;
                    END IF;
                END IF;

            EXCEPTION
                WHEN OTHERS THEN
                    l_errors(i) := SUBSTR(SQLERRM, 1, 4000);
            END;
        END LOOP;

        -- Bulk UPDATE failed rows only — clear CHUNK_ID so stale IDs
        -- never block the row from being picked up cleanly on the next run
        FORALL i IN 1 .. l_msgs.COUNT
            UPDATE AD_SALES_ORDER_BIP_MASTER
               SET RUN_STATUS  = CASE
                                     WHEN l_msgs(i).retry_enabled = 'Y'
                                      AND l_msgs(i).retry_count    < l_msgs(i).max_retry_count
                                     THEN 'RETRY'
                                     ELSE 'ERROR'
                                 END,
                   RETRY_COUNT = NVL(RETRY_COUNT, 0) + 1,
                   CHUNK_ID    = NULL
             WHERE GROUP_NAME  = l_group_names(i)
               AND l_errors(i) IS NOT NULL;
        COMMIT;

        DBMS_OUTPUT.PUT_LINE('DISPATCH_BIP_CHUNK [' || p_chunk_id || '] completed '
                             || SYSTIMESTAMP);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.DISPATCH_BIP_CHUNK',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM,
                p_notes          => 'chunk_id=' || p_chunk_id
            );
            DBMS_OUTPUT.PUT_LINE('DISPATCH_BIP_CHUNK fatal: ' || SQLERRM);
            RAISE;
    END DISPATCH_BIP_CHUNK;



    -- =========================================================================
    -- RETRY_FAILED_MSGS  (public)
    -- For each active interface with RETRY_ENABLED = 'Y', promotes ERROR rows
    -- back to RETRY status where the interface's RETRY_CONDITION is satisfied
    -- and RETRY_COUNT < MAX_RETRY_COUNT.
    -- RETRY_CONDITION is appended as a dynamic WHERE clause to the UPDATE.
    -- =========================================================================
    PROCEDURE RETRY_FAILED_MSGS IS

        CURSOR cr_interfaces IS
            SELECT RETRY_CONDITION,
                   MAX_RETRY_COUNT,
                   INTERFACE_ID,
                   STAGE_NUMBER
              FROM AD_INT_MASTER A
             WHERE STATUS             = 'A'
               AND INTERFACE_CATEGORY IN ('Processor', 'PostProcessor')
               AND RETRY_ENABLED      = 'Y'
               AND RETRY_CONDITION    IS NOT NULL
               AND MAX_RETRY_COUNT    > 0;

        l_retry_status VARCHAR2(100) := 'RETRY';
        l_error_status VARCHAR2(100) := 'ERROR';
        l_user         VARCHAR2(200) := SYS_CONTEXT('userenv', 'current_schema');

    BEGIN
        FOR rec IN cr_interfaces LOOP
            BEGIN
                EXECUTE IMMEDIATE
                    'UPDATE AD_MSG_AUDIT B
                        SET STATUS           = :1,
                            RETRY_COUNT      = NVL(RETRY_COUNT, 0) + 1,
                            LAST_UPDATE_DATE = SYSDATE,
                            LAST_UPDATED_BY  = :2
                      WHERE B.INTERFACE_ID   = :3
                        AND B.STAGE_NUMBER   = :4
                        AND B.STATUS         = :5
                        AND NVL(B.RETRY_COUNT, 0) < :6
                        AND (B.MSG_SEQUENCE IS NULL
                             OR (B.MSG_SEQUENCE IS NOT NULL
                                 AND NOT EXISTS
                                     (SELECT 1
                                        FROM AD_MSG_AUDIT C
                                       WHERE C.INTERFACE_ID  = B.INTERFACE_ID
                                         AND C.STAGE_NUMBER  = B.STAGE_NUMBER
                                         AND C.MSG_SEQUENCE  = B.MSG_SEQUENCE
                                         AND C.STATUS IN (''PROCESSING'', ''TEMP''))))
                      ' || rec.RETRY_CONDITION
                    USING l_retry_status, l_user,
                          rec.INTERFACE_ID, rec.STAGE_NUMBER,
                          l_error_status, rec.MAX_RETRY_COUNT;
                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN
                    ROLLBACK;
                    p_log_error
                    (
                        p_procedure_name => 'AD_PARKING_LOT_PKG.RETRY_FAILED_MSGS',
                        p_error_code     => SQLCODE,
                        p_error_message  => SQLERRM,
                        p_interface_id   => rec.INTERFACE_ID,
                        p_stage_number   => rec.STAGE_NUMBER
                    );
            END;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.RETRY_FAILED_MSGS',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM
            );
    END RETRY_FAILED_MSGS;


    -- =========================================================================
    -- FETCH_GROUP_DISPATCHER_RECORDS  (public)
    -- Loads QUEUED/RETRY rows into AD_GROUP_DISPATCHER_READY_GT and
    -- TEMP/PROCESSING rows into AD_GROUP_DISPATCHER_NOT_READY_GT for the given
    -- dispatcher integration, applies serial-sequence filtering (deletes rows
    -- whose sequence > minimum), then returns eligible ready rows as
    -- AD_GROUP_DISPATCHER_TYPE, capped by p_limit.
    -- =========================================================================
    PROCEDURE FETCH_GROUP_DISPATCHER_RECORDS
    (
        p_limit                           IN  NUMBER,
        p_dispatcher_integration_code     IN  VARCHAR2,
        p_dispatcher_integration_instance IN  VARCHAR2,
        x_fetch_status                    OUT VARCHAR2,
        x_fetch_message                   OUT VARCHAR2,
        x_object_data_table               OUT AD_GROUP_DISPATCHER_TYPE
    )
    IS
        CURSOR cr_data_ready IS
            SELECT /*+ parallel(4) */
                   DISTINCT a.last_update_date,
                   a.MSG_SEQUENCE, a.PARENT_MSG_SEQUENCE, a.MSG_SUB_GROUP_ID,
                   a.INTERFACE_ID, a.SOURCE_SYSTEM, a.TARGET_SYSTEM,
                   a.STAGE_NUMBER, b.execution_type
              FROM AD_MSG_AUDIT  a,
                   AD_INT_MASTER b
             WHERE a.status IN ('QUEUED', 'RETRY')
               AND b.INTERFACE_ID                  = a.INTERFACE_ID
               AND b.STAGE_NUMBER                  = a.STAGE_NUMBER
               AND b.STATUS                        = 'A'
               AND b.OIC_DISPATCHER_INTEGRATION_CODE = p_dispatcher_integration_code
               AND b.OIC_DISPATCHER_INSTANCE_NAME    = p_dispatcher_integration_instance;

        CURSOR cr_data_not_ready IS
            SELECT /*+ parallel(4) */
                   DISTINCT a.last_update_date,
                   a.MSG_SEQUENCE, a.PARENT_MSG_SEQUENCE, a.MSG_SUB_GROUP_ID,
                   a.INTERFACE_ID, a.SOURCE_SYSTEM, a.TARGET_SYSTEM,
                   a.STAGE_NUMBER, b.execution_type
              FROM AD_MSG_AUDIT  a,
                   AD_INT_MASTER b
             WHERE a.status IN ('TEMP', 'PROCESSING')
               AND b.INTERFACE_ID                  = a.INTERFACE_ID
               AND b.STAGE_NUMBER                  = a.STAGE_NUMBER
               AND b.STATUS                        = 'A'
               AND b.OIC_DISPATCHER_INTEGRATION_CODE = p_dispatcher_integration_code
               AND b.OIC_DISPATCHER_INSTANCE_NAME    = p_dispatcher_integration_instance;

        TYPE table_ready     IS TABLE OF cr_data_ready%ROWTYPE     INDEX BY PLS_INTEGER;
        TYPE table_not_ready IS TABLE OF cr_data_not_ready%ROWTYPE INDEX BY PLS_INTEGER;

        l_ready     table_ready;
        l_not_ready table_not_ready;

    BEGIN

        -- ## Data Ready
        OPEN cr_data_ready;
        LOOP
            FETCH cr_data_ready BULK COLLECT INTO l_ready LIMIT 3000;
            EXIT WHEN l_ready.COUNT = 0;
            FORALL i IN 1 .. l_ready.COUNT SAVE EXCEPTIONS
                INSERT INTO AD_GROUP_DISPATCHER_READY_GT
                (
                    MSG_SEQUENCE, PARENT_MSG_SEQUENCE, MSG_SUB_GROUP_ID,
                    INTERFACE_ID, SOURCE_SYSTEM, TARGET_SYSTEM,
                    STAGE_NUMBER, LAST_UPDATE_DATE, EXECUTION_TYPE
                )
                VALUES
                (
                    l_ready(i).MSG_SEQUENCE, l_ready(i).PARENT_MSG_SEQUENCE,
                    l_ready(i).MSG_SUB_GROUP_ID, l_ready(i).INTERFACE_ID,
                    l_ready(i).SOURCE_SYSTEM, l_ready(i).TARGET_SYSTEM,
                    l_ready(i).STAGE_NUMBER, l_ready(i).last_update_date,
                    l_ready(i).execution_type
                );
        END LOOP;
        CLOSE cr_data_ready;

        -- ## Data Not Ready
        OPEN cr_data_not_ready;
        LOOP
            FETCH cr_data_not_ready BULK COLLECT INTO l_not_ready LIMIT 3000;
            EXIT WHEN l_not_ready.COUNT = 0;
            FORALL i IN 1 .. l_not_ready.COUNT SAVE EXCEPTIONS
                INSERT INTO AD_GROUP_DISPATCHER_NOT_READY_GT
                (
                    MSG_SEQUENCE, PARENT_MSG_SEQUENCE, MSG_SUB_GROUP_ID,
                    INTERFACE_ID, SOURCE_SYSTEM, TARGET_SYSTEM,
                    STAGE_NUMBER, LAST_UPDATE_DATE, EXECUTION_TYPE
                )
                VALUES
                (
                    l_not_ready(i).MSG_SEQUENCE, l_not_ready(i).PARENT_MSG_SEQUENCE,
                    l_not_ready(i).MSG_SUB_GROUP_ID, l_not_ready(i).INTERFACE_ID,
                    l_not_ready(i).SOURCE_SYSTEM, l_not_ready(i).TARGET_SYSTEM,
                    l_not_ready(i).STAGE_NUMBER, l_not_ready(i).last_update_date,
                    l_not_ready(i).execution_type
                );
        END LOOP;
        CLOSE cr_data_not_ready;

        -- ## Delete serial rows with PARENT_MSG_SEQUENCE > minimum
        FOR rec IN
        (
            SELECT INTERFACE_ID, STAGE_NUMBER,
                   MIN(PARENT_MSG_SEQUENCE) AS min_PARENT_MSG_SEQUENCE
              FROM (
                       SELECT INTERFACE_ID, STAGE_NUMBER, PARENT_MSG_SEQUENCE, EXECUTION_TYPE
                         FROM AD_GROUP_DISPATCHER_READY_GT
                        UNION ALL
                       SELECT INTERFACE_ID, STAGE_NUMBER, PARENT_MSG_SEQUENCE, EXECUTION_TYPE
                         FROM AD_GROUP_DISPATCHER_NOT_READY_GT
                   )
             WHERE PARENT_MSG_SEQUENCE IS NOT NULL
               AND EXECUTION_TYPE = 'S'
             GROUP BY INTERFACE_ID, STAGE_NUMBER
        )
        LOOP
            DELETE /*+ parallel(4) */ FROM AD_GROUP_DISPATCHER_READY_GT
             WHERE INTERFACE_ID          = rec.INTERFACE_ID
               AND STAGE_NUMBER          = rec.STAGE_NUMBER
               AND PARENT_MSG_SEQUENCE   IS NOT NULL
               AND PARENT_MSG_SEQUENCE   > rec.min_PARENT_MSG_SEQUENCE;
        END LOOP;

        -- ## Delete serial rows with MSG_SEQUENCE > minimum (no parent)
        FOR rec IN
        (
            SELECT INTERFACE_ID, STAGE_NUMBER,
                   MIN(MSG_SEQUENCE) AS min_MSG_SEQUENCE
              FROM (
                       SELECT INTERFACE_ID, STAGE_NUMBER, PARENT_MSG_SEQUENCE, MSG_SEQUENCE, EXECUTION_TYPE
                         FROM AD_GROUP_DISPATCHER_READY_GT
                        UNION ALL
                       SELECT INTERFACE_ID, STAGE_NUMBER, PARENT_MSG_SEQUENCE, MSG_SEQUENCE, EXECUTION_TYPE
                         FROM AD_GROUP_DISPATCHER_NOT_READY_GT
                   )
             WHERE PARENT_MSG_SEQUENCE IS NULL
               AND EXECUTION_TYPE = 'S'
             GROUP BY INTERFACE_ID, STAGE_NUMBER
        )
        LOOP
            DELETE /*+ parallel(4) */ FROM AD_GROUP_DISPATCHER_READY_GT
             WHERE INTERFACE_ID        = rec.INTERFACE_ID
               AND STAGE_NUMBER        = rec.STAGE_NUMBER
               AND PARENT_MSG_SEQUENCE IS NULL
               AND MSG_SEQUENCE        > rec.min_MSG_SEQUENCE;
        END LOOP;

        -- ## Return eligible ready rows
        SELECT AD_GROUP_DISPATCHER_OBJ
               (
                   a.MSG_SEQUENCE, a.PARENT_MSG_SEQUENCE, a.MSG_SUB_GROUP_ID,
                   a.INTERFACE_ID, a.SOURCE_SYSTEM, a.TARGET_SYSTEM, a.STAGE_NUMBER,
                   b.OIC_PROCESSOR_INTEGRATION_CODE, b.OIC_PROCESSOR_INTEGRATION_VERSION,
                   b.OIC_PROCESSOR_RESOURCE, b.PRIORITY, b.INVOKE_TYPE
               )
          BULK COLLECT INTO x_object_data_table
          FROM AD_GROUP_DISPATCHER_READY_GT a,
               AD_INT_MASTER               b
         WHERE b.INTERFACE_ID                    = a.INTERFACE_ID
           AND b.STAGE_NUMBER                    = a.STAGE_NUMBER
           AND b.STATUS                          = 'A'
           AND b.OUTAGE                          = 'N'
           AND NOT EXISTS
               (
                   SELECT 1
                     FROM AD_INT_MASTER_OUTAGE c
                    WHERE c.interface_id = b.interface_id
                      AND SYSDATE BETWEEN c.start_date AND c.end_date
               )
           AND b.OIC_DISPATCHER_INTEGRATION_CODE   = p_dispatcher_integration_code
           AND b.OIC_DISPATCHER_INSTANCE_NAME       = p_dispatcher_integration_instance
           AND (b.DISPATCH_TYPE = 'GROUP'
                OR (b.DISPATCH_TYPE = 'SUB_GROUP' AND a.MSG_SUB_GROUP_ID IS NOT NULL))
           AND (b.WAITING_TIME = 0
                OR TRUNC((SYSDATE - a.last_update_date) * 24 * 60 * 60) >= b.WAITING_TIME)
         GROUP BY
               a.MSG_SEQUENCE, a.PARENT_MSG_SEQUENCE, a.MSG_SUB_GROUP_ID,
               a.INTERFACE_ID, a.SOURCE_SYSTEM, a.TARGET_SYSTEM, a.STAGE_NUMBER,
               b.OIC_PROCESSOR_INTEGRATION_CODE, b.OIC_PROCESSOR_INTEGRATION_VERSION,
               b.OIC_PROCESSOR_RESOURCE, b.PRIORITY, b.INVOKE_TYPE
         ORDER BY b.PRIORITY, a.PARENT_MSG_SEQUENCE, a.MSG_SEQUENCE,
                  a.STAGE_NUMBER, a.MSG_SUB_GROUP_ID
         OFFSET 0 ROWS FETCH NEXT p_limit ROWS ONLY;

        x_fetch_status  := 'SUCCESS';
        x_fetch_message := '';

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            x_fetch_status  := 'SUCCESS';
            x_fetch_message := 'No records found';
        WHEN OTHERS THEN
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.FETCH_GROUP_DISPATCHER_RECORDS',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM
            );
            x_fetch_status  := 'ERROR';
            x_fetch_message := SUBSTR('Failed at fetching records. '
                                      || SQLCODE || '-' || SQLERRM, 1, 1000);
    END FETCH_GROUP_DISPATCHER_RECORDS;


    -- =========================================================================
    -- ARCHIVE_COLLECT_STATS  (public)
    -- 1. Purges archive tables of records older than 90 days.
    -- 2. Archives PROCESSED msgs and msgs/files older than threshold.
    -- 3. Archives HCM report requests older than 7 days.
    -- 4. Gathers table statistics for key tables.
    -- =========================================================================
    PROCEDURE ARCHIVE_COLLECT_STATS IS
    BEGIN

        -- Purge archived msgs older than 90 days
        BEGIN
            DELETE /*+ parallel(4) */ FROM AD_MSG_AUDIT_ARCHIVE
             WHERE CREATION_DATE <= SYSDATE - 90;
            COMMIT;
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK;
        END;

        -- Purge archived files older than 90 days
        BEGIN
            DELETE /*+ parallel(4) */ FROM AD_FILE_AUDIT_ARCHIVE
             WHERE CREATION_DATE <= SYSDATE - 90;
            COMMIT;
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK;
        END;

        -- Purge archived HCM report requests older than 90 days
        BEGIN
            DELETE /*+ parallel(4) */ FROM AD_HCM_REPORTS_STATUS_ARCHIVE
             WHERE CREATION_DATE <= SYSDATE - 90;
            COMMIT;
        EXCEPTION
            WHEN OTHERS THEN ROLLBACK;
        END;

        -- Archive PROCESSED msgs and msgs older than 90 days not yet processed
        FOR rec IN
        (
            SELECT /*+ parallel(4) */ *
              FROM AD_MSG_AUDIT
             WHERE STATUS = 'PROCESSED'
                OR (CREATION_DATE <= SYSDATE - 90 AND STATUS <> 'PROCESSED')
        )
        LOOP
            BEGIN
                INSERT INTO AD_MSG_AUDIT_ARCHIVE VALUES rec;
                DELETE FROM AD_MSG_AUDIT WHERE MSG_ID = rec.MSG_ID;
                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN ROLLBACK;
            END;
        END LOOP;

        -- Archive files: PROCESSED or older than 21 days
        FOR rec IN
        (
            SELECT /*+ parallel(4) */ *
              FROM AD_FILE_AUDIT
             WHERE STATUS = 'PROCESSED'
                OR (CREATION_DATE <= SYSDATE - 21 AND STATUS <> 'PROCESSED')
        )
        LOOP
            BEGIN
                INSERT INTO AD_FILE_AUDIT_ARCHIVE VALUES rec;
                DELETE FROM AD_FILE_AUDIT WHERE FILE_ID = rec.FILE_ID;
                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN ROLLBACK;
            END;
        END LOOP;

        -- Archive HCM report requests older than 7 days
        FOR rec IN
        (
            SELECT /*+ parallel(4) */ *
              FROM AD_HCM_REPORTS_STATUS
             WHERE CREATION_DATE <= SYSDATE - 7
        )
        LOOP
            BEGIN
                INSERT INTO AD_HCM_REPORTS_STATUS_ARCHIVE VALUES rec;
                DELETE FROM AD_HCM_REPORTS_STATUS WHERE REQUEST_ID = rec.REQUEST_ID;
                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN ROLLBACK;
            END;
        END LOOP;

        -- Gather table statistics
        DBMS_STATS.GATHER_TABLE_STATS(SYS_CONTEXT('userenv','current_schema'), 'AD_MSG_AUDIT',                CASCADE => TRUE);
        DBMS_STATS.GATHER_TABLE_STATS(SYS_CONTEXT('userenv','current_schema'), 'AD_FILE_AUDIT',               CASCADE => TRUE);
        DBMS_STATS.GATHER_TABLE_STATS(SYS_CONTEXT('userenv','current_schema'), 'AD_OIC_SCHEDULER',            CASCADE => TRUE);
        DBMS_STATS.GATHER_TABLE_STATS(SYS_CONTEXT('userenv','current_schema'), 'AD_INT_MASTER',               CASCADE => TRUE);
        DBMS_STATS.GATHER_TABLE_STATS(SYS_CONTEXT('userenv','current_schema'), 'AD_PFX_ITEM_MASTER',          CASCADE => TRUE);
        DBMS_STATS.GATHER_TABLE_STATS(SYS_CONTEXT('userenv','current_schema'), 'AD_INT_MASTER_OUTAGE',        CASCADE => TRUE);
        DBMS_STATS.GATHER_TABLE_STATS(SYS_CONTEXT('userenv','current_schema'), 'AD_HCM_REPORTS_STATUS',       CASCADE => TRUE);
        DBMS_STATS.GATHER_TABLE_STATS(SYS_CONTEXT('userenv','current_schema'), 'AD_AGILITY_SUPPLIER_MASTER',  CASCADE => TRUE);
        DBMS_STATS.GATHER_TABLE_STATS(SYS_CONTEXT('userenv','current_schema'), 'AD_PFX_EXCHANGE_RATES',       CASCADE => TRUE);
        DBMS_STATS.GATHER_TABLE_STATS(SYS_CONTEXT('userenv','current_schema'), 'AD_TR_EXCHANGE_RATES',        CASCADE => TRUE);
        DBMS_STATS.GATHER_TABLE_STATS(SYS_CONTEXT('userenv','current_schema'), 'AD_PFX_CUSTOMER_MASTER',      CASCADE => TRUE);
        DBMS_STATS.GATHER_TABLE_STATS(SYS_CONTEXT('userenv','current_schema'), 'AD_SUPPLY_BRAIN_REQ_LINES',   CASCADE => TRUE);
        DBMS_STATS.GATHER_TABLE_STATS(SYS_CONTEXT('userenv','current_schema'), 'AD_QUARK_ITEMS',              CASCADE => TRUE);
        DBMS_STATS.GATHER_TABLE_STATS(SYS_CONTEXT('userenv','current_schema'), 'AD_QUARK_ITEM_MASTER',        CASCADE => TRUE);
        DBMS_STATS.GATHER_TABLE_STATS(SYS_CONTEXT('userenv','current_schema'), 'AD_MSG_AUDIT_ARCHIVE',        CASCADE => TRUE);
        DBMS_STATS.GATHER_TABLE_STATS(SYS_CONTEXT('userenv','current_schema'), 'AD_SALES_ORDER_BIP_MASTER',   CASCADE => TRUE);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.ARCHIVE_COLLECT_STATS',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM
            );
    END ARCHIVE_COLLECT_STATS;


    -- =========================================================================
    -- PERSIST_SALES_ORDER_DATA  (public — wrapper)
    -- Called directly by OIC. Delegates to ACTUAL_PERSIST_SALES_ORDER_DATA.
    -- Direct call avoids EXECUTE IMMEDIATE CLOB copy overhead.
    -- =========================================================================
    PROCEDURE PERSIST_SALES_ORDER_DATA
    (
        p_clob                        IN CLOB,
        p_oic_persister_instance_id   IN VARCHAR2,
        p_oic_persister_instance_name IN VARCHAR2
    )
    IS
    BEGIN
        -- Direct call — no EXECUTE IMMEDIATE to avoid CLOB copy overhead.
        -- LOB locators are passed by reference so no data is copied.
        ACTUAL_PERSIST_SALES_ORDER_DATA
        (
            p_clob                        => p_clob,
            p_oic_persister_instance_id   => p_oic_persister_instance_id,
            p_oic_persister_instance_name => p_oic_persister_instance_name
        );
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.PERSIST_SALES_ORDER_DATA',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM
            );
    END PERSIST_SALES_ORDER_DATA;


    -- =========================================================================
    -- ACTUAL_PERSIST_SALES_ORDER_DATA  (public — inner implementation)
    -- p_clob: pre-decoded text CLOB containing CSV content
    --
    -- FIX (2026-06-10):
    --   After the carry-forward partial-line block, SUBSTR(l_chunk, l_ci + 1)
    --   returns NULL when l_ci = l_chunk_len (LF was the last character of the
    --   chunk). LENGTH(NULL) = NULL in Oracle, so the subsequent inner DECLARE
    --   loop called INSTR(NULL, ...) = 0, immediately stored NULL into l_field
    --   and exited — silently dropping every row in the remainder of that chunk.
    --   Fix: guard the chunk truncation with an explicit boundary check and use
    --   NVL(LENGTH(...), 0) everywhere l_chunk_len is reassigned.
    -- =========================================================================
    PROCEDURE ACTUAL_PERSIST_SALES_ORDER_DATA
    (
        p_clob                        IN CLOB,
        p_oic_persister_instance_id   IN VARCHAR2,
        p_oic_persister_instance_name IN VARCHAR2
    )
    IS
        -- ── Interface config ──────────────────────────────────────────────────
        TYPE t_intf_rec IS RECORD
        (
            interface_id   AD_INT_MASTER.INTERFACE_ID%TYPE,
            interface_type AD_INT_MASTER.INTERFACE_TYPE%TYPE,
            source_system  AD_INT_MASTER.SOURCE_SYSTEM%TYPE,
            target_system  AD_INT_MASTER.TARGET_SYSTEM%TYPE
        );
        TYPE t_intf_tab IS TABLE OF t_intf_rec INDEX BY PLS_INTEGER;
        l_intfs      t_intf_tab;
        l_intf_count PLS_INTEGER := 0;

        -- ── Batch collections ─────────────────────────────────────────────────
        TYPE t_ad_msg_audit_rec IS RECORD
        (
            interface_id       AD_MSG_AUDIT.INTERFACE_ID%TYPE,
            interface_type     AD_MSG_AUDIT.INTERFACE_TYPE%TYPE,
            source_system      AD_MSG_AUDIT.SOURCE_SYSTEM%TYPE,
            target_system      AD_MSG_AUDIT.TARGET_SYSTEM%TYPE,
            sales_order_id     AD_MSG_AUDIT.BUSINESS_IDENTIFIER1%TYPE,
            sales_order_number AD_MSG_AUDIT.BUSINESS_IDENTIFIER2%TYPE,
            business_unit_name AD_MSG_AUDIT.BUSINESS_IDENTIFIER3%TYPE
        );
        TYPE t_ad_msg_audit_tab IS TABLE OF t_ad_msg_audit_rec;
        c_batch_size  CONSTANT PLS_INTEGER := 1000;
        l_data        t_ad_msg_audit_tab   := t_ad_msg_audit_tab();
        l_batch_row   PLS_INTEGER          := 0;

        -- ── CSV chunked read ──────────────────────────────────────────────────
        c_chunk_size  CONSTANT PLS_INTEGER := 8000;
        l_chunk       VARCHAR2(8000);
        l_chunk_len   PLS_INTEGER;
        l_lob_offset  PLS_INTEGER          := 1;
        l_amount      PLS_INTEGER;

        -- ── Parse state ───────────────────────────────────────────────────────
        l_in_quotes   BOOLEAN              := FALSE;
        l_prev_cr     BOOLEAN              := FALSE;
        l_field       VARCHAR2(32767)      := '';
        l_field_num   PLS_INTEGER          := 1;
        l_line_num    PLS_INTEGER          := 0;
        l_ch          VARCHAR2(1);
        l_next_ch     VARCHAR2(1);
        l_ci          PLS_INTEGER;

        -- ── Parsed row values ─────────────────────────────────────────────────
        l_sales_order_id     VARCHAR2(50);
        l_sales_order_number VARCHAR2(100);
        l_business_unit_name VARCHAR2(200);

        -- ── Sequence + totals ─────────────────────────────────────────────────
        l_msg_sequence NUMBER;
        l_total        PLS_INTEGER := 0;

        l_dml_errors  EXCEPTION;
        PRAGMA EXCEPTION_INIT(l_dml_errors, -24381);

        -- ─────────────────────────────────────────────────────────────────────
        -- flush_batch
        -- ─────────────────────────────────────────────────────────────────────
        PROCEDURE flush_batch IS
        BEGIN
            IF l_batch_row = 0 THEN RETURN; END IF;
            BEGIN
                FORALL i IN 1 .. l_batch_row SAVE EXCEPTIONS
                    INSERT INTO AD_MSG_AUDIT
                    (
                        MSG_ID, MSG_OBJECT_ID, MSG_SEQUENCE,
                        INTERFACE_ID, INTERFACE_TYPE, SOURCE_SYSTEM, TARGET_SYSTEM,
                        STAGE_NUMBER, OIC_PERSISTER_INSTANCE_ID, OIC_PERSISTER_INSTANCE_NAME,
                        STATUS, BUSINESS_IDENTIFIER1, BUSINESS_IDENTIFIER2, BUSINESS_IDENTIFIER3
                    )
                    VALUES
                    (
                        AD_MSG_AUDIT_SEQ.NEXTVAL,
                        l_data(i).interface_type
                            || '|' || l_data(i).source_system
                            || '|' || l_data(i).target_system
                            || '|' || l_data(i).business_unit_name
                            || '|' || l_data(i).sales_order_number
                            || '|' || l_data(i).interface_id
                            || '|' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'),
                        l_msg_sequence,
                        l_data(i).interface_id,   l_data(i).interface_type,
                        l_data(i).source_system,  l_data(i).target_system,
                        1,
                        p_oic_persister_instance_id, p_oic_persister_instance_name,
                        'QUEUED',
                        l_data(i).sales_order_id,
                        l_data(i).sales_order_number,
                        l_data(i).business_unit_name
                    );
            EXCEPTION
                WHEN l_dml_errors THEN
                    FOR j IN 1 .. SQL%BULK_EXCEPTIONS.COUNT LOOP
                        DBMS_OUTPUT.PUT_LINE
                        (
                            'interface_id=' || l_data(SQL%BULK_EXCEPTIONS(j).ERROR_INDEX).interface_id
                            || ' batch row ' || SQL%BULK_EXCEPTIONS(j).ERROR_INDEX
                            || ' ORA-'       || SQL%BULK_EXCEPTIONS(j).ERROR_CODE
                        );
                    END LOOP;
            END;
            l_total     := l_total + l_batch_row;
            l_batch_row := 0;
            l_data.DELETE;
            COMMIT;
        END flush_batch;

        -- ─────────────────────────────────────────────────────────────────────
        -- commit_row
        -- ─────────────────────────────────────────────────────────────────────
        PROCEDURE commit_row IS
        BEGIN
            IF l_line_num           <= 1 THEN RETURN; END IF;
            IF l_sales_order_id     IS NULL THEN RETURN; END IF;
            IF l_sales_order_number IS NULL THEN RETURN; END IF;
            IF l_business_unit_name IS NULL THEN RETURN; END IF;
            FOR idx IN 1 .. l_intf_count LOOP
                l_batch_row := l_batch_row + 1;
                l_data.EXTEND;
                l_data(l_batch_row).interface_id       := l_intfs(idx).interface_id;
                l_data(l_batch_row).interface_type     := l_intfs(idx).interface_type;
                l_data(l_batch_row).source_system      := l_intfs(idx).source_system;
                l_data(l_batch_row).target_system      := l_intfs(idx).target_system;
                l_data(l_batch_row).sales_order_id     := l_sales_order_id;
                l_data(l_batch_row).sales_order_number := l_sales_order_number;
                l_data(l_batch_row).business_unit_name := l_business_unit_name;
                IF l_batch_row >= c_batch_size THEN flush_batch; END IF;
            END LOOP;
        END commit_row;

        -- ─────────────────────────────────────────────────────────────────────
        -- end_of_field / end_of_line
        -- ─────────────────────────────────────────────────────────────────────
        PROCEDURE end_of_field IS
        BEGIN
            CASE l_field_num
                WHEN 1 THEN l_sales_order_id     := TRIM(l_field);
                WHEN 2 THEN l_sales_order_number := TRIM(l_field);
                WHEN 3 THEN l_business_unit_name := TRIM(l_field);
                ELSE NULL;
            END CASE;
            l_field     := '';
            l_field_num := l_field_num + 1;
        END end_of_field;

        PROCEDURE end_of_line IS
        BEGIN
            CASE l_field_num
                WHEN 1 THEN l_sales_order_id     := TRIM(l_field);
                WHEN 2 THEN l_sales_order_number := TRIM(l_field);
                WHEN 3 THEN l_business_unit_name := TRIM(l_field);
                ELSE NULL;
            END CASE;
            l_line_num := l_line_num + 1;
            commit_row;
            l_field              := '';
            l_field_num          := 1;
            l_sales_order_id     := NULL;
            l_sales_order_number := NULL;
            l_business_unit_name := NULL;
            l_in_quotes          := FALSE;
        END end_of_line;

    BEGIN

        -- ── Guard: empty input ────────────────────────────────────────────────
        IF p_clob IS NULL OR DBMS_LOB.GETLENGTH(p_clob) = 0 THEN
            DBMS_OUTPUT.PUT_LINE('ACTUAL_PERSIST_SALES_ORDER_DATA: empty input');
            RETURN;
        END IF;

        -- ── Phase 1: Strip UTF-8 BOM if present ──────────────────────────────
        IF DBMS_LOB.GETLENGTH(p_clob) >= 1
           AND DBMS_LOB.SUBSTR(p_clob, 1, 1) = UNISTR('\FEFF')
        THEN
            l_lob_offset := 2;
            DBMS_OUTPUT.PUT_LINE('ACTUAL_PERSIST_SALES_ORDER_DATA: UTF-8 BOM stripped');
        END IF;

        -- ── Phase 2: Load interface config ───────────────────────────────────
        FOR r IN
        (
            SELECT INTERFACE_ID, INTERFACE_TYPE, SOURCE_SYSTEM, TARGET_SYSTEM
              FROM AD_INT_MASTER
             WHERE INTERFACE_TYPE     = 'SalesOrder'
               AND STATUS             = 'A'
               AND STAGE_NUMBER       = 1
               AND INTERFACE_CATEGORY = 'Processor'
               AND SOURCE_SYSTEM      = 'ERP'
        )
        LOOP
            l_intf_count := l_intf_count + 1;
            l_intfs(l_intf_count).interface_id   := r.INTERFACE_ID;
            l_intfs(l_intf_count).interface_type := r.INTERFACE_TYPE;
            l_intfs(l_intf_count).source_system  := r.SOURCE_SYSTEM;
            l_intfs(l_intf_count).target_system  := r.TARGET_SYSTEM;
        END LOOP;

        IF l_intf_count = 0 THEN
            DBMS_OUTPUT.PUT_LINE('ACTUAL_PERSIST_SALES_ORDER_DATA: no active interface');
            RETURN;
        END IF;

        -- ── Phase 3: Message sequence ─────────────────────────────────────────
        SELECT TO_NUMBER(TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS'))
          INTO l_msg_sequence
          FROM DUAL;

        -- ── Phase 4: CSV parse over text CLOB ────────────────────────────────
        LOOP
            l_amount := c_chunk_size;
            BEGIN
                DBMS_LOB.READ(p_clob, l_amount, l_lob_offset, l_chunk);
            EXCEPTION
                WHEN NO_DATA_FOUND THEN EXIT;
            END;
            l_lob_offset := l_lob_offset + l_amount;
            l_chunk_len  := NVL(LENGTH(l_chunk), 0);   -- FIX: NVL guards NULL

            -- Normalise CR+LF → LF, lone CR → LF
            IF INSTR(l_chunk, CHR(13)) > 0 THEN
                l_chunk     := REPLACE(l_chunk, CHR(13) || CHR(10), CHR(10));
                l_chunk     := REPLACE(l_chunk, CHR(13), CHR(10));
                l_chunk_len := NVL(LENGTH(l_chunk), 0); -- FIX: NVL guards NULL
            END IF;

            -- ── Fast path: no quotes in this chunk ───────────────────────────
            IF INSTR(l_chunk, '"') = 0 AND NOT l_in_quotes THEN

                -- Complete any partial line carried from the previous chunk
                IF l_field IS NOT NULL OR l_field_num > 1
                   OR l_sales_order_id IS NOT NULL
                THEN
                    l_ci := INSTR(l_chunk, CHR(10));
                    IF l_ci > 0 THEN
                        -- Append up to (but not including) the LF and parse
                        l_field := l_field || SUBSTR(l_chunk, 1, l_ci - 1);
                        DECLARE
                            l_p1 PLS_INTEGER;
                            l_p2 PLS_INTEGER;
                        BEGIN
                            l_p1 := INSTR(l_field, ',', 1, 1);
                            l_p2 := INSTR(l_field, ',', 1, 2);
                            IF l_p1 > 0 AND l_p2 > 0 THEN
                                l_sales_order_id     := TRIM(SUBSTR(l_field, 1,      l_p1 - 1));
                                l_sales_order_number := TRIM(SUBSTR(l_field, l_p1+1, l_p2 - l_p1 - 1));
                                l_business_unit_name := TRIM(SUBSTR(l_field, l_p2+1));
                                l_line_num := l_line_num + 1;
                                commit_row;
                            END IF;
                        END;
                        -- Reset partial-line state
                        l_field              := '';
                        l_field_num          := 1;
                        l_sales_order_id     := NULL;
                        l_sales_order_number := NULL;
                        l_business_unit_name := NULL;

                        -- FIX: guard chunk truncation against boundary LF
                        IF l_ci >= l_chunk_len THEN
                            GOTO next_chunk;
                        END IF;

                        l_chunk     := SUBSTR(l_chunk, l_ci + 1);
                        l_chunk_len := NVL(LENGTH(l_chunk), 0); -- FIX: NVL guards NULL

                        IF l_chunk_len = 0 THEN
                            GOTO next_chunk;
                        END IF;
                    ELSE
                        -- No LF in chunk — entire chunk extends the partial line
                        l_field := l_field || l_chunk;
                        GOTO next_chunk;
                    END IF;
                END IF;

                -- Process all complete lines in the (remaining) chunk
                DECLARE
                    l_line_start PLS_INTEGER := 1;
                    l_lf_pos     PLS_INTEGER;
                    l_line       VARCHAR2(32767);
                    l_p1         PLS_INTEGER;
                    l_p2         PLS_INTEGER;
                BEGIN
                    LOOP
                        -- FIX: guard against NULL chunk reaching the inner loop
                        IF l_chunk IS NULL OR l_chunk_len = 0 THEN
                            l_field := '';
                            EXIT;
                        END IF;

                        l_lf_pos := INSTR(l_chunk, CHR(10), l_line_start);

                        IF l_lf_pos = 0 THEN
                            -- No more LF — tail is a partial line; carry forward
                            -- FIX: only carry if there is actually content left
                            IF l_line_start <= l_chunk_len THEN
                                l_field := SUBSTR(l_chunk, l_line_start);
                            ELSE
                                l_field := '';
                            END IF;
                            EXIT;
                        END IF;

                        l_line       := SUBSTR(l_chunk, l_line_start, l_lf_pos - l_line_start);
                        l_line_start := l_lf_pos + 1;

                        -- Skip blank lines
                        IF LENGTH(TRIM(l_line)) = 0 THEN CONTINUE; END IF;

                        l_line_num := l_line_num + 1;

                        -- Skip header (line 1)
                        IF l_line_num = 1 THEN CONTINUE; END IF;

                        -- Parse 3 fields
                        l_p1 := INSTR(l_line, ',', 1, 1);
                        l_p2 := INSTR(l_line, ',', 1, 2);

                        IF l_p1 > 0 AND l_p2 > 0 THEN
                            l_sales_order_id     := TRIM(SUBSTR(l_line, 1,      l_p1 - 1));
                            l_sales_order_number := TRIM(SUBSTR(l_line, l_p1+1, l_p2 - l_p1 - 1));
                            l_business_unit_name := TRIM(SUBSTR(l_line, l_p2+1));

                            IF  l_sales_order_id     IS NOT NULL
                            AND l_sales_order_number IS NOT NULL
                            AND l_business_unit_name IS NOT NULL
                            THEN
                                commit_row;
                            END IF;

                            l_sales_order_id     := NULL;
                            l_sales_order_number := NULL;
                            l_business_unit_name := NULL;
                        END IF;
                    END LOOP;
                END;

            -- ── Slow path: chunk contains quotes — character-by-character ─────
            ELSE
                l_ci := 1;
                WHILE l_ci <= l_chunk_len LOOP
                    l_ch := SUBSTR(l_chunk, l_ci, 1);

                    IF l_in_quotes THEN
                        IF l_ch = '"' THEN
                            IF l_ci < l_chunk_len THEN
                                l_next_ch := SUBSTR(l_chunk, l_ci + 1, 1);
                                IF l_next_ch = '"' THEN
                                    l_field := l_field || '"';
                                    l_ci    := l_ci + 2;
                                ELSE
                                    l_in_quotes := FALSE;
                                    l_ci        := l_ci + 1;
                                END IF;
                            ELSE
                                l_in_quotes := FALSE;
                                l_ci        := l_ci + 1;
                            END IF;
                        ELSE
                            l_field := l_field || l_ch;
                            l_ci    := l_ci + 1;
                        END IF;
                    ELSE
                        IF    l_ch = '"'     THEN l_in_quotes := TRUE; l_ci := l_ci + 1;
                        ELSIF l_ch = ','     THEN end_of_field; l_ci := l_ci + 1;
                        ELSIF l_ch = CHR(10) THEN end_of_line;  l_ci := l_ci + 1;
                        ELSE
                            l_field := l_field || l_ch;
                            l_ci    := l_ci + 1;
                        END IF;
                    END IF;
                END LOOP;
            END IF;

            <<next_chunk>>
            EXIT WHEN l_amount < c_chunk_size;
        END LOOP;

        -- ── Handle last line if it has no trailing newline ────────────────────
        IF l_field IS NOT NULL
           OR l_sales_order_id     IS NOT NULL
           OR l_sales_order_number IS NOT NULL
        THEN
            IF INSTR(NVL(l_field,''), '"') = 0 AND NOT l_in_quotes THEN
                -- Fast path: parse l_field as a complete CSV line
                IF l_sales_order_id IS NULL THEN
                    DECLARE
                        l_p1 PLS_INTEGER;
                        l_p2 PLS_INTEGER;
                    BEGIN
                        l_p1 := INSTR(l_field, ',', 1, 1);
                        l_p2 := INSTR(l_field, ',', 1, 2);
                        IF l_p1 > 0 AND l_p2 > 0 THEN
                            l_sales_order_id     := TRIM(SUBSTR(l_field, 1,      l_p1 - 1));
                            l_sales_order_number := TRIM(SUBSTR(l_field, l_p1+1, l_p2 - l_p1 - 1));
                            l_business_unit_name := TRIM(SUBSTR(l_field, l_p2+1));
                        END IF;
                    END;
                END IF;
            ELSE
                -- Slow path: field already partially assigned via end_of_field
                CASE l_field_num
                    WHEN 1 THEN l_sales_order_id     := TRIM(l_field);
                    WHEN 2 THEN l_sales_order_number := TRIM(l_field);
                    WHEN 3 THEN l_business_unit_name := TRIM(l_field);
                    ELSE NULL;
                END CASE;
            END IF;
            l_line_num := l_line_num + 1;
            commit_row;
        END IF;

        flush_batch;
        DBMS_OUTPUT.PUT_LINE('Total records inserted: ' || l_total);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            p_log_error
            (
                p_procedure_name => 'AD_PARKING_LOT_PKG.ACTUAL_PERSIST_SALES_ORDER_DATA',
                p_error_code     => SQLCODE,
                p_error_message  => SQLERRM
            );
            RAISE_APPLICATION_ERROR
            (
                -20001,
                'Fatal error in ACTUAL_PERSIST_SALES_ORDER_DATA: ' || SQLERRM
            );
    END ACTUAL_PERSIST_SALES_ORDER_DATA;

END AD_PARKING_LOT_PKG;
