-- =============================================================================
-- DDL_AD_ATP_ERRORS.sql
-- Runtime error log for AD_PARKING_LOT_PKG
-- =============================================================================

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

    -- ── When & where ─────────────────────────────────────────────────────────
    ERROR_TIMESTAMP   TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    PROCEDURE_NAME    VARCHAR2(100)  NOT NULL,

    -- ── What went wrong ───────────────────────────────────────────────────────
    ERROR_CODE        NUMBER,
    ERROR_MESSAGE     VARCHAR2(4000),

    -- ── Free-form notes ───────────────────────────────────────────────────────
    -- Use to record any additional context, e.g.:
    --   "chunk_id=20260610_1_OICDEV env_id=OICDEV"
    --   "BIP group_name=BU_CN002_2026Q1 failed on HTTP 500"
    NOTES             VARCHAR2(1000)
);

-- ── B-Tree Indexes ────────────────────────────────────────────────────────────
CREATE INDEX AD_ATP_ERRORS_N1 ON AD_ATP_ERRORS (ERROR_TIMESTAMP DESC);
CREATE INDEX AD_ATP_ERRORS_N2 ON AD_ATP_ERRORS (PROCEDURE_NAME, ERROR_TIMESTAMP DESC);
CREATE INDEX AD_ATP_ERRORS_N3 ON AD_ATP_ERRORS (INTERFACE_ID, STAGE_NUMBER);
CREATE INDEX AD_ATP_ERRORS_N4 ON AD_ATP_ERRORS (MSG_ID) ;
