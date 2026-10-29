-- =============================================================================
-- AD_ATP_ERRORS_AIR.sql
-- After-insert row trigger on AD_ATP_ERRORS
-- Enqueues a notification when SEND_EMAIL = 'Y' in AD_ATP_ERRORS_NOTIFICATIONS.
-- EMAIL_SENT on AD_ATP_ERRORS is updated to 'Y' by the OIC consumer process
-- after the email is successfully sent.
-- =============================================================================

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
