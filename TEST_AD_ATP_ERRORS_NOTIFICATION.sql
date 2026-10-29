-- =============================================================================
-- TEST_AD_ATP_ERRORS_NOTIFICATION.sql
-- Tests the AD_ATP_ERRORS_AIR trigger and queue enqueue flow
-- =============================================================================

-- ── Step 1: Seed notification config ─────────────────────────────────────────
-- Configure which parking lot procedures send email notifications

INSERT INTO AD_ATP_ERRORS_NOTIFICATIONS (PROCEDURE_NAME, SEND_EMAIL)
VALUES ('AD_PARKING_LOT_PKG.DISPATCH', 'Y');

INSERT INTO AD_ATP_ERRORS_NOTIFICATIONS (PROCEDURE_NAME, SEND_EMAIL)
VALUES ('AD_PARKING_LOT_PKG.SEQUENCE_MSGS', 'Y');

INSERT INTO AD_ATP_ERRORS_NOTIFICATIONS (PROCEDURE_NAME, SEND_EMAIL)
VALUES ('AD_PARKING_LOT_PKG.REMOVE_DUPLICATES', 'N');  -- silent, no email

COMMIT;

-- ── Step 2: Insert an error for a procedure configured with SEND_EMAIL = 'Y' ─
-- This should fire the trigger and enqueue a payload into AD_ATP_ERRORS_Q

INSERT INTO AD_ATP_ERRORS
(
    MSG_ID,
    MSG_SEQUENCE,
    INTERFACE_ID,
    STAGE_NUMBER,
    PROCEDURE_NAME,
    ERROR_CODE,
    ERROR_MESSAGE,
    NOTES
)
VALUES
(
    1001,
    1,
    'AR_INVOICES_OUT',
    1,
    'AD_PARKING_LOT_PKG.DISPATCH',   -- SEND_EMAIL = 'Y' → should enqueue
    -20001,
    'ORA-20001: OIC call failed with HTTP 500 on environment OICDEV',
    'chunk_id=20261029_1_OICDEV env_id=OICDEV'
);

COMMIT;

-- ── Step 3: Insert an error for a procedure configured with SEND_EMAIL = 'N' ─
-- This should NOT enqueue anything

INSERT INTO AD_ATP_ERRORS
(
    MSG_ID,
    MSG_SEQUENCE,
    INTERFACE_ID,
    STAGE_NUMBER,
    PROCEDURE_NAME,
    ERROR_CODE,
    ERROR_MESSAGE,
    NOTES
)
VALUES
(
    1002,
    1,
    'AR_INVOICES_OUT',
    1,
    'AD_PARKING_LOT_PKG.REMOVE_DUPLICATES',  -- SEND_EMAIL = 'N' → no enqueue
    -20002,
    'ORA-20002: Duplicate removal failed',
    NULL
);

COMMIT;

-- ── Step 4: Insert an error for a procedure NOT in the notifications table ───
-- Should also NOT enqueue (NO_DATA_FOUND → defaults to N)

INSERT INTO AD_ATP_ERRORS
(
    MSG_ID,
    MSG_SEQUENCE,
    INTERFACE_ID,
    STAGE_NUMBER,
    PROCEDURE_NAME,
    ERROR_CODE,
    ERROR_MESSAGE,
    NOTES
)
VALUES
(
    1003,
    1,
    'AP_PAYMENTS_OUT',
    2,
    'AD_PARKING_LOT_PKG.P_DECRYPT_SECRET',  -- not in notifications → silent
    -20003,
    'ORA-20003: AES decryption failed',
    NULL
);

COMMIT;

-- ── Step 5: Results ───────────────────────────────────────────────────────────

-- 5a: What's in the error log
SELECT
    ERROR_ID,
    PROCEDURE_NAME,
    ERROR_CODE,
    ERROR_MESSAGE,
    EMAIL_SENT,
    ERROR_TIMESTAMP
FROM AD_ATP_ERRORS
ORDER BY ERROR_ID;

-- 5b: What's in the notification config
SELECT
    PROCEDURE_NAME,
    SEND_EMAIL
FROM AD_ATP_ERRORS_NOTIFICATIONS
ORDER BY PROCEDURE_NAME;

-- 5c: How many messages are sitting in the queue
--     (should be 1 — only DISPATCH row was enqueued)
SELECT COUNT(*) AS QUEUE_DEPTH
FROM AD_ATP_ERRORS_QT
WHERE Q_NAME = 'AD_ATP_ERRORS_Q';

-- 5d: Peek at the queue payload (without dequeuing)
SELECT
    qt.msgid,
    qt.enq_time,
    qt.user_data.PROCEDURE_NAME  AS PROCEDURE_NAME,
    qt.user_data.ERROR_CODE      AS ERROR_CODE,
    qt.user_data.ERROR_MESSAGE   AS ERROR_MESSAGE,
    qt.user_data.INTERFACE_ID    AS INTERFACE_ID
FROM AD_ATP_ERRORS_QT qt
WHERE qt.Q_NAME = 'AD_ATP_ERRORS_Q';
