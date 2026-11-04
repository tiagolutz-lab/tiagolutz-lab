-- =============================================================================
-- 02_persist_pkg.sql
-- AD_FILE_PERSIST_PKG: ordered, stop-on-failure processing of files landed in
-- Object Storage buckets. Buckets, their endpoint URL and their priority order are
-- read from AD_BUCKET_CONFIG.
--
-- Loading: each bucket names its own loader in AD_BUCKET_CONFIG.LOAD_PROCEDURE, called
-- dynamically for every file. The default, LOAD_DEFAULT, loads by file extension.
--
-- Order: oldest object (Object Storage creation time) first, ties broken by name.
-- Each file is loaded and logged in ONE transaction, so a failure rolls back both
-- and the same file is retried next run. A failure stops that bucket, so a newer
-- file never overtakes a failed older one. Ordering is per bucket, so the other
-- buckets carry on.
--
-- Auth: resource principal. Run once as ADMIN:
--   EXEC DBMS_CLOUD_ADMIN.ENABLE_RESOURCE_PRINCIPAL(username => '<SCHEMA>');
--
-- NOTE: sample code written without a database to test against. Validate in a
-- non-production ATP, and replace the placeholder tables/columns/paths.
-- =============================================================================

CREATE OR REPLACE PACKAGE ad_file_persist_pkg AS
  -- LOADER CONTRACT. Any procedure named in AD_BUCKET_CONFIG.LOAD_PROCEDURE must be
  -- callable as (schema-qualified if it is not in this schema):
  --
  --   PROCEDURE my_loader (p_file_uri    IN  VARCHAR2,  -- full URI of the object
  --                        p_object_name IN  VARCHAR2,  -- object name in the bucket
  --                        p_file_id     IN  NUMBER,    -- stamp this on every row loaded
  --                        p_credential  IN  VARCHAR2,  -- pass to DBMS_CLOUD calls
  --                        p_rows_read   OUT NUMBER,
  --                        p_rows_loaded OUT NUMBER);
  --
  -- It must NOT commit, roll back or run DDL: the caller commits the loaded rows and
  -- the AD_FILE_LOG entry together. To fail a file, raise an exception.
  -- The caller needs EXECUTE on the procedure.

  -- Default loader: picks the loading routine by file extension (csv, json, xml).
  PROCEDURE load_default (p_file_uri    IN  VARCHAR2,
                          p_object_name IN  VARCHAR2,
                          p_file_id     IN  NUMBER,
                          p_credential  IN  VARCHAR2,
                          p_rows_read   OUT NUMBER,
                          p_rows_loaded OUT NUMBER);

  -- Processes at most ONE file per call. Returns TRUE if a file was processed.
  FUNCTION process_next (p_bucket_uri  IN VARCHAR2,   -- full bucket URI, ends with /o/
                         p_load_proc   IN VARCHAR2) RETURN BOOLEAN;  -- loader for this bucket

  -- Drains one bucket in order; stops (raises) on the first failure.
  PROCEDURE process_all (p_bucket_uri IN VARCHAR2,
                         p_load_proc  IN VARCHAR2);

  -- Drains every enabled bucket in AD_BUCKET_CONFIG, lowest PRIORITY number first.
  -- A failure stops only that bucket (it is already recorded in AD_FILE_ERROR); the
  -- others still run.
  PROCEDURE process_all_buckets;
END ad_file_persist_pkg;
/

CREATE OR REPLACE PACKAGE BODY ad_file_persist_pkg AS

  c_cred CONSTANT VARCHAR2(30) := 'OCI$RESOURCE_PRINCIPAL';

  -- Autonomous, so the failure record survives the rollback of the file's load.
  PROCEDURE log_failure (p_bucket_uri VARCHAR2, p_object VARCHAR2, p_err VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO ad_file_error (bucket_uri, object_name, error_text)
    VALUES (p_bucket_uri, p_object, SUBSTR(p_err, 1, 4000));
    COMMIT;
  END log_failure;

  -- ---- CSV: stage, then filter on insert -------------------------------------
  PROCEDURE load_csv (p_uri VARCHAR2, p_file_id NUMBER, p_read OUT NUMBER, p_loaded OUT NUMBER) IS
  BEGIN
    DELETE FROM ad_stg_orders;   -- transactional clear (TRUNCATE is DDL and would commit)
    DBMS_CLOUD.COPY_DATA(
      table_name      => 'AD_STG_ORDERS',
      credential_name => c_cred,
      file_uri_list   => p_uri,
      format          => JSON_OBJECT('type' VALUE 'csv', 'skipheaders' VALUE '1'));

    SELECT COUNT(*) INTO p_read FROM ad_stg_orders;

    INSERT INTO ad_tgt_orders (id, country, amount, file_id)
    SELECT s.id, s.country, s.amount, p_file_id
    FROM   ad_stg_orders s
    WHERE  s.country IN (SELECT filter_value FROM ad_filter_config WHERE filter_name = 'ORDER_COUNTRY')
    AND    s.amount > 0;
    p_loaded := SQL%ROWCOUNT;
  END load_csv;

  -- ---- JSON: JSON_TABLE with a filter ----------------------------------------
  PROCEDURE load_json (p_blob BLOB, p_file_id NUMBER, p_read OUT NUMBER, p_loaded OUT NUMBER) IS
  BEGIN
    SELECT COUNT(*) INTO p_read
    FROM   JSON_TABLE(p_blob FORMAT JSON, '$.orders[*]' COLUMNS (id NUMBER PATH '$.id'));

    INSERT INTO ad_tgt_json_orders (id, status, amount, file_id)
    SELECT j.id, j.status, j.amount, p_file_id
    FROM   JSON_TABLE(p_blob FORMAT JSON, '$.orders[*]'
             COLUMNS (id     NUMBER   PATH '$.id',
                      status VARCHAR2(20) PATH '$.status',
                      amount NUMBER   PATH '$.amount')) j
    WHERE  j.status = 'OPEN';
    p_loaded := SQL%ROWCOUNT;
  END load_json;

  -- ---- XML: XMLTABLE with an XPath predicate ---------------------------------
  PROCEDURE load_xml (p_blob BLOB, p_file_id NUMBER, p_read OUT NUMBER, p_loaded OUT NUMBER) IS
    l_xml XMLTYPE := XMLTYPE(p_blob, NLS_CHARSET_ID('AL32UTF8'));
  BEGIN
    SELECT COUNT(*) INTO p_read
    FROM   XMLTABLE('/Ads/Ad' PASSING l_xml COLUMNS id NUMBER PATH 'Id');

    INSERT INTO ad_tgt_ads (id, status, amount, file_id)
    SELECT x.id, x.status, x.amount, p_file_id
    FROM   XMLTABLE('/Ads/Ad[Status="ACTIVE"]' PASSING l_xml
             COLUMNS id     NUMBER       PATH 'Id',
                     status VARCHAR2(20) PATH 'Status',
                     amount NUMBER       PATH 'Amount') x;
    p_loaded := SQL%ROWCOUNT;
  END load_xml;

  -- ---- Default loader: by file extension --------------------------------------
  PROCEDURE load_default (p_file_uri    IN  VARCHAR2,
                          p_object_name IN  VARCHAR2,
                          p_file_id     IN  NUMBER,
                          p_credential  IN  VARCHAR2,
                          p_rows_read   OUT NUMBER,
                          p_rows_loaded OUT NUMBER) IS
    l_blob BLOB;
  BEGIN
    CASE
      WHEN LOWER(p_object_name) LIKE '%.csv'  THEN
        load_csv(p_file_uri, p_file_id, p_rows_read, p_rows_loaded);
      WHEN LOWER(p_object_name) LIKE '%.json' THEN
        l_blob := DBMS_CLOUD.GET_OBJECT(p_credential, p_file_uri);
        load_json(l_blob, p_file_id, p_rows_read, p_rows_loaded);
      WHEN LOWER(p_object_name) LIKE '%.xml'  THEN
        l_blob := DBMS_CLOUD.GET_OBJECT(p_credential, p_file_uri);
        load_xml(l_blob, p_file_id, p_rows_read, p_rows_loaded);
      ELSE
        RAISE_APPLICATION_ERROR(-20001, 'Unsupported file type: ' || p_object_name);
    END CASE;
  END load_default;

  -- ---- One file: pick the oldest unprocessed object in a bucket --------------
  FUNCTION process_next (p_bucket_uri IN VARCHAR2,
                         p_load_proc  IN VARCHAR2) RETURN BOOLEAN IS
    l_name    VARCHAR2(1024);
    l_created TIMESTAMP WITH TIME ZONE;
    l_uri     VARCHAR2(4000);
    l_proc    VARCHAR2(400);
    l_file_id NUMBER;
    l_read    NUMBER := 0;
    l_loaded  NUMBER := 0;
  BEGIN
    BEGIN
      SELECT object_name, created
      INTO   l_name, l_created
      FROM  (SELECT o.object_name, o.created
             FROM   DBMS_CLOUD.LIST_OBJECTS(c_cred, p_bucket_uri) o
             WHERE  NOT EXISTS (SELECT 1 FROM ad_file_log f
                                WHERE f.bucket_uri = p_bucket_uri
                                AND   f.object_name = o.object_name)
             ORDER  BY o.created, o.object_name)
      WHERE  ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN RETURN FALSE;
    END;

    l_uri := p_bucket_uri || l_name;

    -- Reserve the id up front so loaded rows can reference the file.
    l_file_id := ad_file_log_seq.NEXTVAL;

    -- The loader name comes from AD_BUCKET_CONFIG. DBMS_ASSERT rejects anything that is
    -- not a (qualified) SQL name, so the value cannot inject SQL; only table writers can
    -- choose the procedure.
    l_proc := DBMS_ASSERT.QUALIFIED_SQL_NAME(p_load_proc);

    EXECUTE IMMEDIATE 'BEGIN ' || l_proc || '(:1, :2, :3, :4, :5, :6); END;'
      USING IN l_uri, IN l_name, IN l_file_id, IN c_cred, OUT l_read, OUT l_loaded;

    INSERT INTO ad_file_log (file_id, bucket_uri, object_name, object_created, rows_read, rows_loaded)
    VALUES (l_file_id, p_bucket_uri, l_name, l_created, l_read, l_loaded);

    COMMIT;   -- rows + log entry together
    RETURN TRUE;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      log_failure(p_bucket_uri, l_name, SQLERRM);
      RAISE;   -- stop this bucket so the order is preserved
  END process_next;

  PROCEDURE process_all (p_bucket_uri IN VARCHAR2,
                         p_load_proc  IN VARCHAR2) IS
  BEGIN
    WHILE process_next(p_bucket_uri, p_load_proc) LOOP
      NULL;
    END LOOP;
  END process_all;

  -- ---- All enabled buckets from AD_BUCKET_CONFIG -------------------------------
  PROCEDURE process_all_buckets IS
  BEGIN
    FOR b IN (SELECT bucket_uri, load_procedure
              FROM   ad_bucket_config
              WHERE  enabled = 'Y'
              ORDER  BY priority, bucket_uri)
    LOOP
      BEGIN
        -- RTRIM + '/' so the URI always ends in exactly one slash, because the object
        -- name is appended to it.
        process_all(RTRIM(b.bucket_uri, '/') || '/', b.load_procedure);
      EXCEPTION
        WHEN OTHERS THEN
          NULL;   -- already recorded in AD_FILE_ERROR; ordering is per bucket, so carry on with the others
      END;
    END LOOP;
  END process_all_buckets;

END ad_file_persist_pkg;
/
