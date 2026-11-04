-- =============================================================================
-- 05_json_to_csv_example.sql
-- Example: flatten a multi-layer JSON document (objects inside objects, lists inside
-- lists) into rows with JSON_TABLE, then either insert the rows or write them out as a
-- CSV file. The input is ../examples/json-to-csv/sample_orders.json and the expected
-- result is ../examples/json-to-csv/expected_output.csv (produced and checked with jq).
--
-- Shape of the sample:  batch -> orders[] -> items[] -> discounts[]
--   * one output row per order / item / discount
--   * an order with no items, or an item with no discounts (empty list or missing key),
--     still gives one row with empty cells (NESTED PATH behaves like an outer join)
--
-- NOTE: sample code written without a database to test against. Validate in a
-- non-production ATP; in particular the NESTED PATH outer-join behaviour and
-- DBMS_CLOUD.EXPORT_DATA on 26ai.
-- =============================================================================

-- Staging table that holds one JSON document at a time. The IS JSON check rejects a
-- malformed file with a clear error before any flattening is attempted.
CREATE TABLE ad_stg_json_doc (
  file_id  NUMBER NOT NULL,
  doc      BLOB   NOT NULL,
  CONSTRAINT ad_stg_json_doc_pk PRIMARY KEY (file_id),
  CONSTRAINT ad_stg_json_doc_ck CHECK (doc IS JSON)
);

-- Flat result table (sample columns; adapt to the real target).
CREATE TABLE ad_tgt_orders_flat (
  file_id        NUMBER,
  batch_id       VARCHAR2(20),
  order_id       VARCHAR2(20),
  status         VARCHAR2(20),
  customer_id    VARCHAR2(20),
  customer_name  VARCHAR2(200),
  city           VARCHAR2(100),
  country        VARCHAR2(2),
  sku            VARCHAR2(50),
  qty            NUMBER,
  price          NUMBER,
  discount_code  VARCHAR2(50),
  discount_pct   NUMBER
);

-- ---- Step 1: read the file from the bucket into the staging table -------------------
-- The URI is a placeholder; the bucket is the one the file landed in.
DECLARE
  l_blob BLOB;
BEGIN
  l_blob := DBMS_CLOUD.GET_OBJECT(
              credential_name => 'OCI$RESOURCE_PRINCIPAL',
              object_uri      => 'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/sample_orders.json');
  DELETE FROM ad_stg_json_doc;
  INSERT INTO ad_stg_json_doc (file_id, doc) VALUES (1, l_blob);
  COMMIT;
END;
/

-- ---- Step 2: flatten the nested layers with JSON_TABLE and look at the rows ----------
-- Each NESTED PATH goes one layer deeper; its columns repeat for every element of the
-- list and the parent's columns are repeated on each of those rows.
SELECT j.*
FROM   ad_stg_json_doc s,
       JSON_TABLE(s.doc FORMAT JSON, '$'
         COLUMNS (
           batch_id VARCHAR2(20) PATH '$.batch.id',
           NESTED PATH '$.orders[*]'
             COLUMNS (
               order_id      VARCHAR2(20)  PATH '$.orderId',
               status        VARCHAR2(20)  PATH '$.status',
               customer_id   VARCHAR2(20)  PATH '$.customer.id',
               customer_name VARCHAR2(200) PATH '$.customer.name',
               city          VARCHAR2(100) PATH '$.customer.address.city',
               country       VARCHAR2(2)   PATH '$.customer.address.country',
               NESTED PATH '$.items[*]'
                 COLUMNS (
                   sku   VARCHAR2(50) PATH '$.sku',
                   qty   NUMBER       PATH '$.qty',
                   price NUMBER       PATH '$.price',
                   NESTED PATH '$.discounts[*]'
                     COLUMNS (
                       discount_code VARCHAR2(50) PATH '$.code',
                       discount_pct  NUMBER       PATH '$.pct'))))) j;

-- ---- Step 3a: load the flat rows into a table (no CSV needed) -------------------------
-- This is what the loader should normally do. The filter is an ordinary WHERE.
INSERT INTO ad_tgt_orders_flat
SELECT s.file_id, j.*
FROM   ad_stg_json_doc s,
       JSON_TABLE(s.doc FORMAT JSON, '$'
         COLUMNS (
           batch_id VARCHAR2(20) PATH '$.batch.id',
           NESTED PATH '$.orders[*]'
             COLUMNS (
               order_id      VARCHAR2(20)  PATH '$.orderId',
               status        VARCHAR2(20)  PATH '$.status',
               customer_id   VARCHAR2(20)  PATH '$.customer.id',
               customer_name VARCHAR2(200) PATH '$.customer.name',
               city          VARCHAR2(100) PATH '$.customer.address.city',
               country       VARCHAR2(2)   PATH '$.customer.address.country',
               NESTED PATH '$.items[*]'
                 COLUMNS (
                   sku   VARCHAR2(50) PATH '$.sku',
                   qty   NUMBER       PATH '$.qty',
                   price NUMBER       PATH '$.price',
                   NESTED PATH '$.discounts[*]'
                     COLUMNS (
                       discount_code VARCHAR2(50) PATH '$.code',
                       discount_pct  NUMBER       PATH '$.pct'))))) j
WHERE  j.status = 'OPEN';
COMMIT;

-- ---- Step 3b: write the flat rows out as a CSV file in a bucket ------------------------
-- Use a DIFFERENT bucket (or prefix) from the landing bucket, or the pipeline will pick
-- the CSV up as a new incoming file. The database needs create permission on that bucket.
-- The query is a string, so it reads the staging table rather than a PL/SQL variable.
BEGIN
  DBMS_CLOUD.EXPORT_DATA(
    credential_name => 'OCI$RESOURCE_PRINCIPAL',
    file_uri_list   => 'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<export-bucket>/o/orders_flat',
    format          => JSON_OBJECT('type' VALUE 'csv', 'header' VALUE TRUE),
    query           => q'[
      SELECT j.*
      FROM   ad_stg_json_doc s,
             JSON_TABLE(s.doc FORMAT JSON, '$'
               COLUMNS (
                 batch_id VARCHAR2(20) PATH '$.batch.id',
                 NESTED PATH '$.orders[*]'
                   COLUMNS (
                     order_id      VARCHAR2(20)  PATH '$.orderId',
                     status        VARCHAR2(20)  PATH '$.status',
                     customer_id   VARCHAR2(20)  PATH '$.customer.id',
                     customer_name VARCHAR2(200) PATH '$.customer.name',
                     city          VARCHAR2(100) PATH '$.customer.address.city',
                     country       VARCHAR2(2)   PATH '$.customer.address.country',
                     NESTED PATH '$.items[*]'
                       COLUMNS (
                         sku   VARCHAR2(50) PATH '$.sku',
                         qty   NUMBER       PATH '$.qty',
                         price NUMBER       PATH '$.price',
                         NESTED PATH '$.discounts[*]'
                           COLUMNS (
                             discount_code VARCHAR2(50) PATH '$.code',
                             discount_pct  NUMBER       PATH '$.pct'))))) j]');
END;
/
-- EXPORT_DATA names the file with the given prefix plus its own suffix (for example
-- orders_flat_1_<timestamp>.csv); check the bucket for the exact name.

-- ---- The same flattening outside the database -------------------------------------------
-- On any machine with jq:
--   jq -r -f ../examples/json-to-csv/flatten.jq sample_orders.json > orders_flat.csv
-- The result is expected_output.csv in ../examples/json-to-csv/.
-- That filter loads the whole document into memory, so it suits files of a few hundred
-- MB at most. For files too big for that, a streaming parser (jq --stream, or Python
-- with ijson) is needed, and the filter would have to be rewritten for it.
