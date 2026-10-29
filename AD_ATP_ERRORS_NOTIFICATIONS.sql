-- =============================================================================
-- AD_ATP_ERRORS_NOTIFICATIONS.sql
-- Controls which procedures trigger an email notification on error
-- =============================================================================

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
