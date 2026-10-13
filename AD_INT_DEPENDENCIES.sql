-- =============================================================================
-- AD_INT_DEPENDENCIES.sql
-- Interface dependency rules — controls dispatch sequencing across interfaces.
--
-- A row in this table means:
--   "Do not dispatch INTERFACE_ID / STAGE_NUMBER until all messages for
--    DEPENDS_ON_INTERFACE_ID / DEPENDS_ON_STAGE_NUMBER with the same
--    BUSINESS_IDENTIFIER1 have reached a terminal status (COMPLETED / FAILED)."
--
-- The dispatcher evaluates these rules inside SEQUENCE_MSGS before promoting
-- a row from QUEUED/RETRY to READY_TO_DISPATCH.
--
-- STATUS:  A = Active  |  I = Inactive (rule ignored at runtime)
-- =============================================================================

CREATE TABLE AD_INT_DEPENDENCIES
(
    DEPENDENCY_ID              NUMBER          GENERATED ALWAYS AS IDENTITY,
    INTERFACE_ID               VARCHAR2(200)   NOT NULL,
    STAGE_NUMBER               NUMBER          NOT NULL,
    DEPENDS_ON_INTERFACE_ID    VARCHAR2(200)   NOT NULL,
    DEPENDS_ON_STAGE_NUMBER    NUMBER          NOT NULL,
    STATUS                     VARCHAR2(1)     DEFAULT 'A'     NOT NULL,
    CREATED_BY                 VARCHAR2(500)   DEFAULT USER,
    CREATION_DATE              DATE            DEFAULT SYSDATE,
    LAST_UPDATED_BY            VARCHAR2(500)   DEFAULT USER,
    LAST_UPDATE_DATE           DATE            DEFAULT SYSDATE,
    CONSTRAINT AD_INT_DEP_PK   PRIMARY KEY (DEPENDENCY_ID),
    CONSTRAINT AD_INT_DEP_UK   UNIQUE (
                                   INTERFACE_ID,
                                   STAGE_NUMBER,
                                   DEPENDS_ON_INTERFACE_ID,
                                   DEPENDS_ON_STAGE_NUMBER
                               ),
    CONSTRAINT AD_INT_DEP_SELF_CK CHECK (
                                       INTERFACE_ID          <> DEPENDS_ON_INTERFACE_ID
                                    OR STAGE_NUMBER          <> DEPENDS_ON_STAGE_NUMBER
                               ),
    CONSTRAINT AD_INT_DEP_STAT_CK  CHECK (STATUS IN ('A', 'I'))
);

CREATE INDEX AD_INT_DEP_N1
    ON AD_INT_DEPENDENCIES (INTERFACE_ID, STAGE_NUMBER, STATUS);

CREATE INDEX AD_INT_DEP_N2
    ON AD_INT_DEPENDENCIES (DEPENDS_ON_INTERFACE_ID, DEPENDS_ON_STAGE_NUMBER, STATUS);

COMMENT ON TABLE  AD_INT_DEPENDENCIES IS
    'Cross-interface dispatch dependency rules. A row blocks INTERFACE_ID/STAGE_NUMBER from being promoted to READY_TO_DISPATCH until all messages for DEPENDS_ON_INTERFACE_ID/DEPENDS_ON_STAGE_NUMBER sharing the same BUSINESS_IDENTIFIER1 are in a terminal status.';

COMMENT ON COLUMN AD_INT_DEPENDENCIES.INTERFACE_ID            IS 'The interface that is blocked until the dependency is satisfied.';
COMMENT ON COLUMN AD_INT_DEPENDENCIES.STAGE_NUMBER            IS 'The stage of the blocked interface.';
COMMENT ON COLUMN AD_INT_DEPENDENCIES.DEPENDS_ON_INTERFACE_ID IS 'The interface that must complete before the blocked interface can be dispatched.';
COMMENT ON COLUMN AD_INT_DEPENDENCIES.DEPENDS_ON_STAGE_NUMBER IS 'The stage of the prerequisite interface.';
COMMENT ON COLUMN AD_INT_DEPENDENCIES.STATUS                  IS 'A = Active (enforced at runtime). I = Inactive (rule is skipped).';


-- =============================================================================
-- Example data
-- =============================================================================

-- ── Example: Processor must wait for Persister ────────────────────────────────
-- SalesOrderFromErpToMagma001 (stage 1) cannot be dispatched until
-- SalesOrderFromErp001 (stage 1) has completed for the same business key.
-- This mirrors the typical Persist → Process sequencing pattern.

INSERT INTO AD_INT_DEPENDENCIES
    (INTERFACE_ID, STAGE_NUMBER, DEPENDS_ON_INTERFACE_ID, DEPENDS_ON_STAGE_NUMBER, STATUS)
VALUES
    ('SalesOrderFromErpToMagma001', 1, 'SalesOrderFromErp001', 1, 'A');


-- ── Example: Multi-stage dependency — stage 2 waits for stage 1 ──────────────
-- EmployeeFromHcmToErp001 stage 2 cannot start until stage 1 is complete
-- for the same business key.

INSERT INTO AD_INT_DEPENDENCIES
    (INTERFACE_ID, STAGE_NUMBER, DEPENDS_ON_INTERFACE_ID, DEPENDS_ON_STAGE_NUMBER, STATUS)
VALUES
    ('EmployeeFromHcmToErp001', 2, 'EmployeeFromHcmToErp001', 1, 'A');


COMMIT;


/*
-- =============================================================================
-- Additional dependency patterns (commented out — enable as needed)
-- =============================================================================

-- ── Downstream interface waits for upstream across different categories ────────
-- PostProcessor cannot run until the Processor has finished.

INSERT INTO AD_INT_DEPENDENCIES
    (INTERFACE_ID, STAGE_NUMBER, DEPENDS_ON_INTERFACE_ID, DEPENDS_ON_STAGE_NUMBER, STATUS)
VALUES
    ('<PostProcessor_InterfaceId>', 1, '<Processor_InterfaceId>', 1, 'A');


-- ── Inactive rule — defined but not enforced at runtime ───────────────────────

INSERT INTO AD_INT_DEPENDENCIES
    (INTERFACE_ID, STAGE_NUMBER, DEPENDS_ON_INTERFACE_ID, DEPENDS_ON_STAGE_NUMBER, STATUS)
VALUES
    ('<InterfaceId>', 1, '<PrerequisiteInterfaceId>', 1, 'I');

*/
