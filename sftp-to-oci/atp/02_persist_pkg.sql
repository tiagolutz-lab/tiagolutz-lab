-- =============================================================================
-- 02_persist_pkg.sql
-- Ordered, stop-on-failure processing of files landed in an Object Storage bucket.
--
-- Order: oldest object (Object Storage creation time) first, ties broken by name.
-- Each file is loaded and logged in ONE transaction, so a failure rolls back both
-- and the same file is retried next run. A failure raises, so the scheduler job
-- stops there and a newer file never overtakes a failed older one.
--
-- Auth: resource principal. Run once as ADMIN:
--   EXEC DBMS_CLOUD_ADMIN.ENABLE_RESOURCE_PRINCIPAL(username => '<SCHEMA>');
--
-- NOTE: sample code written without a database to test against. Validate in a
-- non-production ATP, and replace the placeholder tables/columns/paths.
-- =============================================================================

CREATE OR REPLACE PACKAGE file_persist_pkg AS
  -- Processes at most ONE file per call. Returns TRUE if a file was processed.
  FUNCTION process_next (p_bucket_uri IN VARCHAR2,   -- .../n/<ns>/b/<bucket>/o/
                         p_bucket     IN VARCHAR2) RETURN BOOLEAN;

  -- Drains the bucket in order; stops (raises) on the first failure.
  PROCEDURE process_all (p_bucket_uri IN VARCHAR2,
                         p_bucket     IN VARCHAR2);
END file_persist_pkg;
/

CREATE OR REPLACE PACKAGE BODY file_persist_pkg AS

  c_cred CONSTANT VARCHAR2(30) := 'OCI$RESOURCE_PRINCIPAL';

  -- Autonomous, so the failure record survives the rollback of the file's load.
  PROCEDURE log_failure (p_bucket VARCHAR2, p_object VARCHAR2, p_err VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO file_error (bucket_name, object_name, error_text)
    VALUES (p_bucket, p_object, SUBSTR(p_err, 1, 4000));
    COMMIT;
  END log_failure;

  -- ---- CSV: stage, then filter on insert -------------------------------------
  PROCEDURE load_csv (p_uri VARCHAR2, p_file_id NUMBER, p_read OUT NUMBER, p_loaded OUT NUMBER) IS
  BEGIN
    DELETE FROM stg_orders;   -- transactional clear (TRUNCATE is DDL and would commit)
    DBMS_CLOUD.COPY_DATA(
      table_name      => 'STG_ORDERS',
      credential_name => c_cred,
      file_uri_list   => p_uri,
      format          => JSON_OBJECT('type' VALUE 'csv', 'skipheaders' VALUE '1'));

    SELECT COUNT(*) INTO p_read FROM stg_orders;

    INSERT INTO tgt_orders (id, country, amount, file_id)
    SELECT s.id, s.country, s.amount, p_file_id
    FROM   stg_orders s
    WHERE  s.country IN (SELECT filter_value FROM filter_config WHERE filter_name = 'ORDER_COUNTRY')
    AND    s.amount > 0;
    p_loaded := SQL%ROWCOUNT;
  END load_csv;

  -- ---- JSON: JSON_TABLE with a filter ----------------------------------------
  PROCEDURE load_json (p_blob BLOB, p_file_id NUMBER, p_read OUT NUMBER, p_loaded OUT NUMBER) IS
  BEGIN
    SELECT COUNT(*) INTO p_read
    FROM   JSON_TABLE(p_blob FORMAT JSON, '$.orders[*]' COLUMNS (id NUMBER PATH '$.id'));

    INSERT INTO tgt_json_orders (id, status, amount, file_id)
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

    INSERT INTO tgt_ads (id, status, amount, file_id)
    SELECT x.id, x.status, x.amount, p_file_id
    FROM   XMLTABLE('/Ads/Ad[Status="ACTIVE"]' PASSING l_xml
             COLUMNS id     NUMBER       PATH 'Id',
                     status VARCHAR2(20) PATH 'Status',
                     amount NUMBER       PATH 'Amount') x;
    p_loaded := SQL%ROWCOUNT;
  END load_xml;

  -- ---- Main: pick the oldest unprocessed file --------------------------------
  FUNCTION process_next (p_bucket_uri IN VARCHAR2, p_bucket IN VARCHAR2) RETURN BOOLEAN IS
    l_name    VARCHAR2(1024);
    l_created TIMESTAMP WITH TIME ZONE;
    l_uri     VARCHAR2(4000);
    l_blob    BLOB;
    l_file_id NUMBER;
    l_read    NUMBER := 0;
    l_loaded  NUMBER := 0;
  BEGIN
    BEGIN
      SELECT object_name, created
      INTO   l_name, l_created
      FROM  (SELECT o.object_name, o.created
             FROM   DBMS_CLOUD.LIST_OBJECTS(c_cred, p_bucket_uri) o
             WHERE  NOT EXISTS (SELECT 1 FROM file_log f
                                WHERE f.bucket_name = p_bucket
                                AND   f.object_name = o.object_name)
             ORDER  BY o.created, o.object_name)
      WHERE  ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN RETURN FALSE;
    END;

    l_uri := p_bucket_uri || l_name;

    -- Reserve the id up front so loaded rows can reference the file.
    l_file_id := file_log_seq.NEXTVAL;

    CASE
      WHEN LOWER(l_name) LIKE '%.csv'  THEN load_csv(l_uri, l_file_id, l_read, l_loaded);
      WHEN LOWER(l_name) LIKE '%.json' THEN
        l_blob := DBMS_CLOUD.GET_OBJECT(c_cred, l_uri);
        load_json(l_blob, l_file_id, l_read, l_loaded);
      WHEN LOWER(l_name) LIKE '%.xml'  THEN
        l_blob := DBMS_CLOUD.GET_OBJECT(c_cred, l_uri);
        load_xml(l_blob, l_file_id, l_read, l_loaded);
      ELSE
        RAISE_APPLICATION_ERROR(-20001, 'Unsupported file type: ' || l_name);
    END CASE;

    INSERT INTO file_log (file_id, bucket_name, object_name, object_created, rows_read, rows_loaded)
    VALUES (l_file_id, p_bucket, l_name, l_created, l_read, l_loaded);

    COMMIT;   -- rows + log entry together
    RETURN TRUE;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      log_failure(p_bucket, l_name, SQLERRM);
      RAISE;   -- stop here so the order is preserved
  END process_next;

  PROCEDURE process_all (p_bucket_uri IN VARCHAR2, p_bucket IN VARCHAR2) IS
  BEGIN
    WHILE process_next(p_bucket_uri, p_bucket) LOOP
      NULL;
    END LOOP;
  END process_all;

END file_persist_pkg;
/
