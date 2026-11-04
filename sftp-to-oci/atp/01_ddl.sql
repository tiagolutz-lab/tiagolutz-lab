-- =============================================================================
-- 01_ddl.sql
-- Control, config and sample target/staging tables for ordered file persistence.
-- Table and column names for the targets are PLACEHOLDERS: adapt to the real schema.
-- =============================================================================

CREATE SEQUENCE file_log_seq NOCACHE;

-- Successfully processed files only. One row per bucket + object.
-- A file appears here in the same transaction as its loaded rows.
CREATE TABLE file_log (
  file_id         NUMBER PRIMARY KEY,
  bucket_name     VARCHAR2(256)  NOT NULL,
  object_name     VARCHAR2(1024) NOT NULL,
  object_created  TIMESTAMP WITH TIME ZONE,
  rows_read       NUMBER,
  rows_loaded     NUMBER,
  processed_at    TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT file_log_uq UNIQUE (bucket_name, object_name)
);

-- Every failed attempt (append-only). Alert on new rows or repeated failures.
CREATE TABLE file_error (
  error_id     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  bucket_name  VARCHAR2(256)  NOT NULL,
  object_name  VARCHAR2(1024),
  failed_at    TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  error_text   VARCHAR2(4000)
);

-- Filter rules live in data, not code. Example: allowed countries for CSV orders.
CREATE TABLE filter_config (
  filter_name  VARCHAR2(50)  NOT NULL,
  filter_value VARCHAR2(200) NOT NULL,
  CONSTRAINT filter_config_pk PRIMARY KEY (filter_name, filter_value)
);

INSERT INTO filter_config VALUES ('ORDER_COUNTRY', 'IE');
INSERT INTO filter_config VALUES ('ORDER_COUNTRY', 'GB');

-- CSV: staging table (cleared per file) and target.
CREATE TABLE stg_orders (
  id      NUMBER,
  country VARCHAR2(2),
  amount  NUMBER
);

CREATE TABLE tgt_orders (
  id        NUMBER,
  country   VARCHAR2(2),
  amount    NUMBER,
  file_id   NUMBER
);

-- JSON target.
CREATE TABLE tgt_json_orders (
  id      NUMBER,
  status  VARCHAR2(20),
  amount  NUMBER,
  file_id NUMBER
);

-- XML target.
CREATE TABLE tgt_ads (
  id      NUMBER,
  status  VARCHAR2(20),
  amount  NUMBER,
  file_id NUMBER
);
