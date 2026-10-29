-- =============================================================================
-- AD_ATP_ERRORS_ALTER_01.sql
-- Add EMAIL_SENT flag to AD_ATP_ERRORS
-- =============================================================================

ALTER TABLE AD_ATP_ERRORS
    ADD EMAIL_SENT CHAR(1) DEFAULT 'N' NOT NULL
        CONSTRAINT AD_ATP_ERRORS_EMAILSENT_CHK CHECK (EMAIL_SENT IN ('Y', 'N'));

COMMENT ON COLUMN AD_ATP_ERRORS.EMAIL_SENT IS 'N = not yet sent; Y = email sent (updated by OIC consumer after successful send)';
