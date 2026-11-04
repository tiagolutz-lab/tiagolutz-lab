-- =============================================================================
-- 01_ddl.sql
-- Control, config and sample target/staging tables for ordered file persistence.
-- Every custom object starts with AD_.
-- Target table and column names are PLACEHOLDERS: adapt to the real schema.
-- =============================================================================

CREATE SEQUENCE ad_file_log_seq NOCACHE;

-- Buckets to poll. Add a row to start processing a bucket; no code or job change.
-- Set ENABLED = 'N' to pause a bucket without deleting it.
-- BUCKET_URI is the full URI of the bucket, in this form (a trailing / is added if missing):
--   https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/
-- so the endpoint, namespace and bucket are all changed here, not in code.
-- Buckets are read in PRIORITY order: the LOWEST number is read FIRST (1 before 2);
-- equal priorities are read in bucket URI order.
-- LOAD_PROCEDURE is the procedure that loads each file of that bucket (called
-- dynamically). It must have the signature documented in AD_FILE_PERSIST_PKG
-- (02_persist_pkg.sql). The default loads by file extension (csv / json / xml).
-- JOB_NAME is the scheduler job that processes this bucket. Each job picks up only the
-- rows carrying its own name, so the buckets are split across jobs here. A bucket
-- belongs to exactly one job, so two jobs never work on the same bucket and the
-- per-bucket order holds. Create the jobs in 03_scheduler_job.sql; a JOB_NAME with no
-- matching job means the bucket is never processed.
-- ARCHIVE_URI / ERROR_URI are the shared buckets (full bucket URI, may include a prefix)
-- that a loaded file is moved to, or a file that keeps failing is moved to. They can be
-- the same values on every row. Files are stored as
--   <archive or error uri><source bucket name>/<yyyy-mm-dd of creation>/<file_id>_<object name>
-- so integrations sharing a bucket never overwrite each other.
-- MAX_ATTEMPTS is how many failed LOAD attempts a file gets before it is moved to the error
-- bucket and the bucket carries on with the next file. See AD_FILE_PERSIST_PKG.
-- DESCRIPTION says what the bucket holds and which interface it serves.
CREATE TABLE ad_bucket_config (
  bucket_uri      VARCHAR2(500) NOT NULL,
  description     VARCHAR2(500),
  job_name        VARCHAR2(128) DEFAULT 'AD_PERSIST_FILES_A' NOT NULL,
  priority        NUMBER        DEFAULT 100 NOT NULL,
  load_procedure  VARCHAR2(261) DEFAULT 'AD_FILE_PERSIST_PKG.LOAD_DEFAULT' NOT NULL,
  archive_uri     VARCHAR2(500) NOT NULL,
  error_uri       VARCHAR2(500) NOT NULL,
  max_attempts    NUMBER        DEFAULT 3 NOT NULL,
  enabled         VARCHAR2(1)   DEFAULT 'Y' NOT NULL,
  CONSTRAINT ad_bucket_config_pk PRIMARY KEY (bucket_uri),
  CONSTRAINT ad_bucket_config_ck CHECK (enabled IN ('Y', 'N')),
  CONSTRAINT ad_bucket_config_ck2 CHECK (max_attempts >= 1)
);

-- Sample rows are disabled so nothing runs until real values are entered.
INSERT INTO ad_bucket_config (bucket_uri, description, job_name, priority, load_procedure,
                              archive_uri, error_uri, max_attempts, enabled)
VALUES ('https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket-a>/o/',
        'Sample: ad_*.xml files from SFTP server 1', 'AD_PERSIST_FILES_A', 10,
        'AD_FILE_PERSIST_PKG.LOAD_DEFAULT',
        'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<archive-bucket>/o/',
        'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<error-bucket>/o/', 3, 'N');
INSERT INTO ad_bucket_config (bucket_uri, description, job_name, priority, load_procedure,
                              archive_uri, error_uri, max_attempts, enabled)
VALUES ('https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket-b>/o/',
        'Sample: orders CSV files from SFTP server 2', 'AD_PERSIST_FILES_B', 10,
        'AD_FILE_PERSIST_PKG.LOAD_DEFAULT',
        'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<archive-bucket>/o/',
        'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<error-bucket>/o/', 3, 'N');

-- Successfully processed files only. One row per bucket URI + object + creation time, so a
-- later file re-sent under the same name (after the first was deleted) is a new file.
-- A file appears here in the same transaction as its loaded rows.
CREATE TABLE ad_file_log (
  file_id         NUMBER NOT NULL,
  bucket_uri      VARCHAR2(500)  NOT NULL,
  object_name     VARCHAR2(1024) NOT NULL,
  object_created  TIMESTAMP WITH TIME ZONE,
  rows_read       NUMBER,
  rows_loaded     NUMBER,
  processed_at    TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT ad_file_log_pk PRIMARY KEY (file_id),
  CONSTRAINT ad_file_log_uq UNIQUE (bucket_uri, object_name, object_created)
);

-- Every failed attempt (append-only). Alert on new rows or repeated failures.
--   LOAD         the file failed to load (rolled back); counted against MAX_ATTEMPTS
--   MOVE         copying to the archive or error bucket, or the delete after it, failed
--   QUARANTINED  the file was moved to the error bucket (ERROR_TEXT says where): the
--                bucket then carried on, so the load order was deliberately broken
CREATE TABLE ad_file_error (
  error_id     NUMBER GENERATED ALWAYS AS IDENTITY,
  bucket_uri     VARCHAR2(500)  NOT NULL,
  object_name    VARCHAR2(1024),
  object_created TIMESTAMP WITH TIME ZONE,
  error_type     VARCHAR2(12)   NOT NULL,   -- LOAD, MOVE or QUARANTINED
  failed_at      TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  error_text     VARCHAR2(4000),
  CONSTRAINT ad_file_error_pk PRIMARY KEY (error_id),
  CONSTRAINT ad_file_error_ck CHECK (error_type IN ('LOAD', 'MOVE', 'QUARANTINED'))
);

-- Filter rules live in data, not code. Example: allowed countries for CSV orders.
CREATE TABLE ad_filter_config (
  filter_name  VARCHAR2(50)  NOT NULL,
  filter_value VARCHAR2(200) NOT NULL,
  CONSTRAINT ad_filter_config_pk PRIMARY KEY (filter_name, filter_value)
);

INSERT INTO ad_filter_config (filter_name, filter_value) VALUES ('ORDER_COUNTRY', 'IE');
INSERT INTO ad_filter_config (filter_name, filter_value) VALUES ('ORDER_COUNTRY', 'GB');

-- CSV: staging table (cleared per file) and target.
CREATE TABLE ad_stg_orders (
  id      NUMBER,
  country VARCHAR2(2),
  amount  NUMBER
);

CREATE TABLE ad_tgt_orders (
  id        NUMBER,
  country   VARCHAR2(2),
  amount    NUMBER,
  file_id   NUMBER
);

-- JSON target.
CREATE TABLE ad_tgt_json_orders (
  id      NUMBER,
  status  VARCHAR2(20),
  amount  NUMBER,
  file_id NUMBER
);

-- XML target.
CREATE TABLE ad_tgt_ads (
  id      NUMBER,
  status  VARCHAR2(20),
  amount  NUMBER,
  file_id NUMBER
);

COMMIT;
