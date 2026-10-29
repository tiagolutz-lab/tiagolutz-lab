-- =============================================================================
-- AD_ATP_ERRORS_Q.sql
-- Object type, queue table and queue for AD_ATP_ERRORS email notifications
-- =============================================================================

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
