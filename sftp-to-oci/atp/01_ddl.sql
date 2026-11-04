-- =============================================================================
-- 01_ddl.sql
-- Control, config and sample target/staging tables for ordered file persistence.
-- Every custom object starts with AD_.
-- Target table and column names are PLACEHOLDERS: adapt to the real schema.
-- =============================================================================

CREATE SEQUENCE ad_file_log_seq NOCACHE;

-- Buckets to poll. Add a row to start processing a bucket; no code or job change.
-- Set ENABLED = 'N' to pause a bucket without deleting it.
-- The object URI is built as: BASE_URL || '/n/' || NAMESPACE || '/b/' || BUCKET_NAME || '/o/'
-- so the endpoint is changed here, not in code.
-- Buckets are read in PRIORITY order: the LOWEST number is read FIRST (1 before 2);
-- equal priorities are read in bucket-name order.
CREATE TABLE ad_bucket_config (
  bucket_name  VARCHAR2(256)  NOT NULL,
  namespace    VARCHAR2(100)  NOT NULL,   -- Object Storage namespace of the tenancy
  base_url     VARCHAR2(500)  NOT NULL,   -- for example https://objectstorage.eu-dublin-1.oraclecloud.com
  priority     NUMBER         DEFAULT 100 NOT NULL,
  enabled      VARCHAR2(1)    DEFAULT 'Y' NOT NULL,
  CONSTRAINT ad_bucket_config_pk PRIMARY KEY (bucket_name),
  CONSTRAINT ad_bucket_config_ck CHECK (enabled IN ('Y', 'N'))
);

-- Sample rows are disabled so nothing runs until real values are entered.
INSERT INTO ad_bucket_config (bucket_name, namespace, base_url, priority, enabled)
VALUES ('<bucket-a>', '<namespace>', 'https://objectstorage.<region>.oraclecloud.com', 10, 'N');
INSERT INTO ad_bucket_config (bucket_name, namespace, base_url, priority, enabled)
VALUES ('<bucket-b>', '<namespace>', 'https://objectstorage.<region>.oraclecloud.com', 20, 'N');

-- Successfully processed files only. One row per bucket + object.
-- A file appears here in the same transaction as its loaded rows.
CREATE TABLE ad_file_log (
  file_id         NUMBER NOT NULL,
  bucket_name     VARCHAR2(256)  NOT NULL,
  object_name     VARCHAR2(1024) NOT NULL,
  object_created  TIMESTAMP WITH TIME ZONE,
  rows_read       NUMBER,
  rows_loaded     NUMBER,
  processed_at    TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT ad_file_log_pk PRIMARY KEY (file_id),
  CONSTRAINT ad_file_log_uq UNIQUE (bucket_name, object_name)
);

-- Every failed attempt (append-only). Alert on new rows or repeated failures.
CREATE TABLE ad_file_error (
  error_id     NUMBER GENERATED ALWAYS AS IDENTITY,
  bucket_name  VARCHAR2(256)  NOT NULL,
  object_name  VARCHAR2(1024),
  failed_at    TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  error_text   VARCHAR2(4000),
  CONSTRAINT ad_file_error_pk PRIMARY KEY (error_id)
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
