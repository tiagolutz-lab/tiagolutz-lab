-- =============================================================================
-- AD_INT_MASTER_frequency_changes.sql
-- Adds dispatch-frequency columns to AD_INT_MASTER.
--
-- DISPATCH_FREQUENCY  VARCHAR2(4000)
--   One or more DBMS_SCHEDULER calendar expressions, pipe-separated.
--   NULL = no frequency gate; messages are promoted to READY_TO_DISPATCH
--   whenever the existing sequencing rules allow (default / existing behavior).
--
--   Example values — see DDL_F_NEXT_DISPATCH_DATE.sql for the full list:
--     'FREQ=HOURLY;INTERVAL=4'
--     'FREQ=DAILY;BYHOUR=2,16;BYMINUTE=0;BYSECOND=0'
--     'FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=1;BYMINUTE=0;BYSECOND=0|
--      FREQ=MONTHLY;BYMONTHDAY=5;BYHOUR=17;BYMINUTE=0;BYSECOND=0'
--
-- LAST_DISPATCHED_DATE  DATE
--   Set by SEQUENCE_MSGS after each successful promotion batch.
--   Used as the return_date_after anchor in F_NEXT_DISPATCH_DATE so the
--   next fire time advances past the last dispatch — no duplicate promotions
--   between scheduled windows.
-- =============================================================================

ALTER TABLE AD_INT_MASTER
    ADD DISPATCH_FREQUENCY   VARCHAR2(4000) DEFAULT NULL;

ALTER TABLE AD_INT_MASTER
    ADD LAST_DISPATCHED_DATE DATE           DEFAULT NULL;

COMMENT ON COLUMN AD_INT_MASTER.DISPATCH_FREQUENCY IS
    'Pipe-separated DBMS_SCHEDULER calendar expression(s) controlling how often messages are promoted to READY_TO_DISPATCH. NULL = always due (no frequency gate). Example: FREQ=DAILY;BYHOUR=2,16;BYMINUTE=0;BYSECOND=0';

COMMENT ON COLUMN AD_INT_MASTER.LAST_DISPATCHED_DATE IS
    'Timestamp of the last successful promotion batch for this interface. Set by SEQUENCE_MSGS. Used as the anchor for F_NEXT_DISPATCH_DATE to prevent duplicate dispatches within a scheduled window.';

COMMIT;


-- =============================================================================
-- Discovery query: interfaces with QUEUED/RETRY messages, frequency-gate aware
--
-- Shows only interfaces that are currently DUE for dispatch (frequency check
-- passes). Interfaces with NULL DISPATCH_FREQUENCY are always included.
--
-- Usage: run ad-hoc to see what SEQUENCE_MSGS would promote right now.
-- =============================================================================

/*
SELECT
    m.INTERFACE_ID,
    m.STAGE_NUMBER,
    m.DISPATCH_TYPE,
    m.DISPATCH_FREQUENCY,
    m.LAST_DISPATCHED_DATE,
    F_NEXT_DISPATCH_DATE(m.DISPATCH_FREQUENCY, m.LAST_DISPATCHED_DATE) AS next_dispatch_due,
    COUNT(a.MSG_ID) AS queued_count
FROM AD_MSG_AUDIT  a
JOIN AD_INT_MASTER m
  ON  m.INTERFACE_ID  = a.INTERFACE_ID
 AND  m.STAGE_NUMBER  = a.STAGE_NUMBER
 AND  m.STATUS        = 'A'
WHERE a.STATUS IN ('QUEUED', 'RETRY')
  AND (   m.DISPATCH_FREQUENCY IS NULL
       OR F_NEXT_DISPATCH_DATE(m.DISPATCH_FREQUENCY, m.LAST_DISPATCHED_DATE) <= SYSDATE)
GROUP BY
    m.INTERFACE_ID,
    m.STAGE_NUMBER,
    m.DISPATCH_TYPE,
    m.DISPATCH_FREQUENCY,
    m.LAST_DISPATCHED_DATE,
    F_NEXT_DISPATCH_DATE(m.DISPATCH_FREQUENCY, m.LAST_DISPATCHED_DATE)
ORDER BY m.INTERFACE_ID, m.STAGE_NUMBER;
*/
