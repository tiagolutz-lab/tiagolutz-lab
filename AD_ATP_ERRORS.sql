-- =============================================================================
-- AD_ATP_ERRORS.sql
-- Runtime error log, notification config, Advanced Queue and insert trigger
-- for AD_PARKING_LOT_PKG
-- =============================================================================

-- ── 1. Main error log ─────────────────────────────────────────────────────────
CREATE TABLE AD_ATP_ERRORS
(
    -- ── Identity ──────────────────────────────────────────────────────────────
    ERROR_ID          NUMBER         GENERATED ALWAYS AS IDENTITY
                                     (START WITH 1 INCREMENT BY 1 NOCACHE)
                                     CONSTRAINT AD_ATP_ERRORS_PK1 PRIMARY KEY,

    -- ── Business context ──────────────────────────────────────────────────────
    MSG_ID            NUMBER,
    MSG_SEQUENCE      NUMBER,
    INTERFACE_ID      VARCHAR2(100),
    STAGE_NUMBER      NUMBER,

    -- ── When & where ──────────────────────────────────────────────────────────
    ERROR_TIMESTAMP   TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    PROCEDURE_NAME    VARCHAR2(100)  NOT NULL,

    -- ── What went wrong ───────────────────────────────────────────────────────
    ERROR_CODE        NUMBER,
    ERROR_MESSAGE     VARCHAR2(4000),

    -- ── Free-form notes ───────────────────────────────────────────────────────
    -- Use to record any additional context, e.g.:
    --   "chunk_id=20260610_1_OICDEV env_id=OICDEV"
    --   "BIP group_name=BU_CN002_2026Q1 failed on HTTP 500"
    NOTES             VARCHAR2(1000),

    -- ── Email notification ────────────────────────────────────────────────────
    -- N = not yet sent; Y = email sent (updated by OIC consumer after send)
    EMAIL_SENT        CHAR(1)        DEFAULT 'N' NOT NULL
                                     CONSTRAINT AD_ATP_ERRORS_EMAILSENT_CHK
                                         CHECK (EMAIL_SENT IN ('Y', 'N'))
);

-- ── B-Tree Indexes ────────────────────────────────────────────────────────────
CREATE INDEX AD_ATP_ERRORS_N1 ON AD_ATP_ERRORS (ERROR_TIMESTAMP DESC);
CREATE INDEX AD_ATP_ERRORS_N2 ON AD_ATP_ERRORS (PROCEDURE_NAME, ERROR_TIMESTAMP DESC);
CREATE INDEX AD_ATP_ERRORS_N3 ON AD_ATP_ERRORS (INTERFACE_ID, STAGE_NUMBER);
CREATE INDEX AD_ATP_ERRORS_N4 ON AD_ATP_ERRORS (MSG_ID);


-- ── 2. Notification config ────────────────────────────────────────────────────
CREATE TABLE AD_ATP_ERRORS_NOTIFICATIONS
(
    PROCEDURE_NAME    VARCHAR2(100)  NOT NULL
                                     CONSTRAINT AD_ATP_ERRORS_NOTIF_PK PRIMARY KEY,
    SEND_EMAIL        CHAR(1)        NOT NULL
                                     CONSTRAINT AD_ATP_ERRORS_NOTIF_SE
                                         CHECK (SEND_EMAIL IN ('Y', 'N'))
);

COMMENT ON COLUMN AD_ATP_ERRORS_NOTIFICATIONS.PROCEDURE_NAME IS 'Fully-qualified procedure name, e.g. AD_PARKING_LOT_PKG.DISPATCH';
COMMENT ON COLUMN AD_ATP_ERRORS_NOTIFICATIONS.SEND_EMAIL     IS 'Y = enqueue for email notification; N = silent (log only)';


-- ── 3. Advanced Queue ─────────────────────────────────────────────────────────
CREATE OR REPLACE TYPE AD_ATP_ERROR_PAYLOAD AS OBJECT
(
    ERROR_ID          NUMBER,
    MSG_ID            NUMBER,
    MSG_SEQUENCE      NUMBER,
    INTERFACE_ID      VARCHAR2(100),
    STAGE_NUMBER      NUMBER,
    ERROR_TIMESTAMP   TIMESTAMP,
    PROCEDURE_NAME    VARCHAR2(100),
    ERROR_CODE        NUMBER,
    ERROR_MESSAGE     VARCHAR2(4000),
    NOTES             VARCHAR2(1000)
);
/

BEGIN
    DBMS_AQADM.CREATE_QUEUE_TABLE
    (
        queue_table        => 'AD_ATP_ERRORS_QT',
        queue_payload_type => 'AD_ATP_ERROR_PAYLOAD',
        comment            => 'Queue table for AD_ATP_ERRORS email notifications'
    );
END;
/

BEGIN
    DBMS_AQADM.CREATE_QUEUE
    (
        queue_name  => 'AD_ATP_ERRORS_Q',
        queue_table => 'AD_ATP_ERRORS_QT',
        comment     => 'Error notification queue; dequeued by OIC email-sending process'
    );
END;
/

BEGIN
    DBMS_AQADM.START_QUEUE(queue_name => 'AD_ATP_ERRORS_Q');
END;
/


-- ── 4. After-insert trigger ───────────────────────────────────────────────────
CREATE OR REPLACE TRIGGER AD_ATP_ERRORS_AIR
    AFTER INSERT ON AD_ATP_ERRORS
    FOR EACH ROW
DECLARE
    l_send_email   AD_ATP_ERRORS_NOTIFICATIONS.SEND_EMAIL%TYPE;
    l_payload      AD_ATP_ERROR_PAYLOAD;
    l_enqueue_opts DBMS_AQ.ENQUEUE_OPTIONS_T;
    l_msg_props    DBMS_AQ.MESSAGE_PROPERTIES_T;
    l_msg_handle   RAW(16);
BEGIN
    -- ── Check notification config for this procedure ──────────────────────────
    BEGIN
        SELECT SEND_EMAIL
          INTO l_send_email
          FROM AD_ATP_ERRORS_NOTIFICATIONS
         WHERE PROCEDURE_NAME = :NEW.PROCEDURE_NAME;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            l_send_email := 'N';   -- not configured → silent
    END;

    IF l_send_email = 'Y' THEN
        -- ── Build payload ─────────────────────────────────────────────────────
        l_payload := AD_ATP_ERROR_PAYLOAD
        (
            ERROR_ID        => :NEW.ERROR_ID,
            MSG_ID          => :NEW.MSG_ID,
            MSG_SEQUENCE    => :NEW.MSG_SEQUENCE,
            INTERFACE_ID    => :NEW.INTERFACE_ID,
            STAGE_NUMBER    => :NEW.STAGE_NUMBER,
            ERROR_TIMESTAMP => :NEW.ERROR_TIMESTAMP,
            PROCEDURE_NAME  => :NEW.PROCEDURE_NAME,
            ERROR_CODE      => :NEW.ERROR_CODE,
            ERROR_MESSAGE   => :NEW.ERROR_MESSAGE,
            NOTES           => :NEW.NOTES
        );

        -- ── Enqueue ───────────────────────────────────────────────────────────
        DBMS_AQ.ENQUEUE
        (
            queue_name         => 'AD_ATP_ERRORS_Q',
            enqueue_options    => l_enqueue_opts,
            message_properties => l_msg_props,
            payload            => l_payload,
            msgid              => l_msg_handle
        );
    END IF;
END AD_ATP_ERRORS_AIR;
/
