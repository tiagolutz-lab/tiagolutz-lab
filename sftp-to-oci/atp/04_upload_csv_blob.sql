-- =============================================================================
-- 04_upload_csv_blob.sql
-- Uploads a .csv held in the database as a BLOB into an Object Storage bucket.
-- Use it to feed test files into a bucket so the persistence job can be tested
-- without SFTP, or to publish a CSV that the database generated.
--
-- Uses DBMS_CLOUD.PUT_OBJECT with the resource principal. The database's policy must
-- allow OBJECT_CREATE (and OBJECT_OVERWRITE if the object name can repeat) on the
-- TARGET bucket; the production policy in ../iam/policy.example.txt does not grant
-- create on the source buckets, so for tests use a test bucket with its own statement.
--
-- NOTE: sample code written without a database to test against. Validate in a
-- non-production ATP.
-- =============================================================================

-- Uploads any BLOB as one object. The contents are written as-is.
-- p_bucket_uri : full bucket URI ending in /o/ (the BUCKET_URI of AD_BUCKET_CONFIG)
-- p_object_name: the object name to create, for example orders_20261104120000.csv
CREATE OR REPLACE PROCEDURE ad_upload_csv_blob (
  p_bucket_uri  IN VARCHAR2,
  p_object_name IN VARCHAR2,
  p_csv         IN BLOB) IS
BEGIN
  IF p_csv IS NULL OR DBMS_LOB.GETLENGTH(p_csv) = 0 THEN
    RAISE_APPLICATION_ERROR(-20010, 'Refusing to upload an empty file: ' || p_object_name);
  END IF;

  DBMS_CLOUD.PUT_OBJECT(
    credential_name => 'OCI$RESOURCE_PRINCIPAL',
    object_uri      => RTRIM(p_bucket_uri, '/') || '/' || p_object_name,
    contents        => p_csv);
END ad_upload_csv_blob;
/

-- ---- Example 1: build a small CSV in memory and upload it -------------------------
-- The columns match AD_STG_ORDERS (id, country, amount) with a header row, so the
-- default loader (AD_FILE_PERSIST_PKG.LOAD_DEFAULT) will pick it up from a bucket that
-- is enabled in AD_BUCKET_CONFIG. Only IE and GB rows with amount > 0 are loaded.
DECLARE
  l_csv  BLOB;
  l_text VARCHAR2(4000) :=
       'id,country,amount' || CHR(10)
    || '1,IE,100.50'       || CHR(10)
    || '2,GB,20'           || CHR(10)
    || '3,US,75'           || CHR(10);   -- filtered out: country not in AD_FILTER_CONFIG
  l_raw  RAW(32767);
BEGIN
  DBMS_LOB.CREATETEMPORARY(l_csv, TRUE);
  l_raw := UTL_I18N.STRING_TO_RAW(l_text, 'AL32UTF8');   -- UTF-8 bytes
  DBMS_LOB.WRITEAPPEND(l_csv, UTL_RAW.LENGTH(l_raw), l_raw);

  ad_upload_csv_blob(
    p_bucket_uri  => 'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<test-bucket>/o/',
    p_object_name => 'orders_' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDD"T"HH24MISS') || '.csv',
    p_csv         => l_csv);

  DBMS_LOB.FREETEMPORARY(l_csv);
END;
/

-- ---- Example 2: upload a CSV already stored as a BLOB column ----------------------
-- Replace my_csv_table / csv_blob / file_name with the real table and columns.
-- BEGIN
--   FOR r IN (SELECT file_name, csv_blob FROM my_csv_table WHERE file_id = :id) LOOP
--     ad_upload_csv_blob('https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/',
--                        r.file_name, r.csv_blob);
--   END LOOP;
-- END;
-- /

-- Check it arrived:
-- SELECT object_name, bytes, created
-- FROM   DBMS_CLOUD.LIST_OBJECTS('OCI$RESOURCE_PRINCIPAL',
--          'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<test-bucket>/o/');
