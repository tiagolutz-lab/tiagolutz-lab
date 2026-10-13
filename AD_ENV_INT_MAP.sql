-- =============================================================================
-- 03_DDL_AD_ENV_INT_MAP.sql
-- New table: interface-to-environment weighted allocation map
-- ALLOCATION_PCT across all active rows per (INTERFACE_ID, STAGE_NUMBER) MUST = 100
-- ALLOCATION_TYPE: STATIC = pure % split | DYNAMIC = % weighted by live capacity
-- =============================================================================

CREATE TABLE AD_ENV_INT_MAP
(
    MAP_ID           NUMBER         GENERATED ALWAYS AS IDENTITY,
    INTERFACE_ID     VARCHAR2(200)  NOT NULL,
    STAGE_NUMBER     NUMBER         NOT NULL,
    ENV_ID           VARCHAR2(100)  NOT NULL,
    ALLOCATION_PCT   NUMBER         NOT NULL,
    ALLOCATION_TYPE  VARCHAR2(10)   DEFAULT 'STATIC' NOT NULL,
    STATUS           VARCHAR2(1)    DEFAULT 'A'      NOT NULL,
    CREATED_BY       VARCHAR2(500)  DEFAULT USER,
    CREATION_DATE    DATE           DEFAULT SYSDATE,
    LAST_UPDATED_BY  VARCHAR2(500)  DEFAULT USER,
    LAST_UPDATE_DATE DATE           DEFAULT SYSDATE,
    CONSTRAINT AD_ENV_INT_MAP_PK       PRIMARY KEY (MAP_ID),
    CONSTRAINT AD_ENV_INT_MAP_UK       UNIQUE  (INTERFACE_ID, STAGE_NUMBER, ENV_ID),
    CONSTRAINT AD_ENV_INT_MAP_ENV_FK   FOREIGN KEY (ENV_ID)
                                           REFERENCES AD_OIC_ENVIRONMENTS (ENV_ID),
    CONSTRAINT AD_ENV_INT_MAP_PCT_CK   CHECK (ALLOCATION_PCT BETWEEN 1 AND 100),
    CONSTRAINT AD_ENV_INT_MAP_TYPE_CK  CHECK (ALLOCATION_TYPE IN ('STATIC', 'DYNAMIC')),
    CONSTRAINT AD_ENV_INT_MAP_STAT_CK  CHECK (STATUS IN ('A', 'I'))
);

CREATE INDEX AD_ENV_INT_MAP_N1
    ON AD_ENV_INT_MAP (INTERFACE_ID, STAGE_NUMBER, STATUS);

CREATE INDEX AD_ENV_INT_MAP_N2
    ON AD_ENV_INT_MAP (ENV_ID, STATUS);

COMMENT ON TABLE  AD_ENV_INT_MAP                   IS 'Maps each interface+stage to one or more OIC environments with a % allocation. Active rows per (INTERFACE_ID, STAGE_NUMBER) must sum to 100.';
COMMENT ON COLUMN AD_ENV_INT_MAP.ALLOCATION_PCT    IS 'Percentage of messages routed to this environment. Active rows per interface+stage must sum to exactly 100.';
COMMENT ON COLUMN AD_ENV_INT_MAP.ALLOCATION_TYPE   IS 'STATIC: pure percentage split. DYNAMIC: percentage weighted by live running instance count via OIC API. API failure falls back to STATIC.';


-- ── Example Two envs, dynamic 50/50 ───────────────────────────────────────
-- Base split is 50/50 but adjusted at runtime by live running instance counts.
-- Less busy env receives proportionally more messages.
-- If OIC API call fails for either env, falls back to static 50/50.
 
INSERT INTO AD_ENV_INT_MAP
    (INTERFACE_ID, STAGE_NUMBER, ENV_ID, ALLOCATION_PCT, ALLOCATION_TYPE, STATUS)
VALUES
    ('SalesOrderFromErpToMagma001', 1, 'OICDEV', 50, 'DYNAMIC', 'A');
 
INSERT INTO AD_ENV_INT_MAP
    (INTERFACE_ID, STAGE_NUMBER, ENV_ID, ALLOCATION_PCT, ALLOCATION_TYPE, STATUS)
VALUES
    ('SalesOrderFromErpToMagma001', 1, 'OICAMODEV5', 50, 'DYNAMIC', 'A');


INSERT INTO AD_ENV_INT_MAP
    (INTERFACE_ID, STAGE_NUMBER, ENV_ID, ALLOCATION_PCT, ALLOCATION_TYPE, STATUS)
VALUES
    ('SalesOrderFromErp001', 1, 'OICDEV',100, 'STATIC', 'A');


COMMIT;
	
/*	

INSERT INTO AD_ENV_INT_MAP
    (INTERFACE_ID, STAGE_NUMBER, ENV_ID, ALLOCATION_PCT, ALLOCATION_TYPE, STATUS)
VALUES
    ('EmployeeFromHcmToErp001', 1, 'OICDEV', 50, 'DYNAMIC', 'A');
	
INSERT INTO AD_ENV_INT_MAP
    (INTERFACE_ID, STAGE_NUMBER, ENV_ID, ALLOCATION_PCT, ALLOCATION_TYPE, STATUS)
VALUES
    ('EmployeeFromHcmToErp001', 1, 'OICAMODEV5', 50, 'DYNAMIC', 'A');	

INSERT INTO AD_ENV_INT_MAP
    (INTERFACE_ID, STAGE_NUMBER, ENV_ID, ALLOCATION_PCT, ALLOCATION_TYPE, STATUS)
VALUES
    ('EmployeeFromHcmToErp001', 2, 'OICDEV', 50, 'DYNAMIC', 'A');
	
INSERT INTO AD_ENV_INT_MAP
    (INTERFACE_ID, STAGE_NUMBER, ENV_ID, ALLOCATION_PCT, ALLOCATION_TYPE, STATUS)
VALUES
    ('EmployeeFromHcmToErp001', 2, 'OICAMODEV5', 50, 'DYNAMIC', 'A');	

INSERT INTO AD_ENV_INT_MAP
    (INTERFACE_ID, STAGE_NUMBER, ENV_ID, ALLOCATION_PCT, ALLOCATION_TYPE, STATUS)
VALUES
    ('SupplierMasterFromErpToAgility001', 1, 'OICDEV', 50, 'DYNAMIC', 'A');

INSERT INTO AD_ENV_INT_MAP
    (INTERFACE_ID, STAGE_NUMBER, ENV_ID, ALLOCATION_PCT, ALLOCATION_TYPE, STATUS)
VALUES
    ('SupplierMasterFromErpToAgility001', 1, 'OICAMODEV5', 50, 'DYNAMIC', 'A');

*/




/*
-- Example Single env, 100% static ───────────────────────────────────────
-- All messages go to OIC_PRD. Simple, no load balancing needed.
 
INSERT INTO AD_ENV_INT_MAP
    (INTERFACE_ID, STAGE_NUMBER, ENV_ID, ALLOCATION_PCT, ALLOCATION_TYPE, STATUS)
VALUES
    ('SalesOrderFromErpToMagma001', 1, 'OIC_PRD', 100, 'STATIC', 'A');
 
 
-- ── Example Two envs, static 60/40 split ──────────────────────────────────
-- 60% of messages go to OIC_PRD, 40% to OIC_PRD_DR.
-- Split is fixed regardless of how busy each environment is.
 
INSERT INTO AD_ENV_INT_MAP
    (INTERFACE_ID, STAGE_NUMBER, ENV_ID, ALLOCATION_PCT, ALLOCATION_TYPE, STATUS)
VALUES
    ('InvoiceFromErpToWms001', 1, 'OIC_PRD', 60, 'STATIC', 'A');
 
INSERT INTO AD_ENV_INT_MAP
    (INTERFACE_ID, STAGE_NUMBER, ENV_ID, ALLOCATION_PCT, ALLOCATION_TYPE, STATUS)
VALUES
    ('InvoiceFromErpToWms001', 1, 'OIC_PRD_DR', 40, 'STATIC', 'A');
 
*/

