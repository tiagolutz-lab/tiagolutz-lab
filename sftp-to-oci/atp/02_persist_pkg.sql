-- =============================================================================
-- 02_persist_pkg.sql
-- AD_FILE_PERSIST_PKG: ordered, stop-on-failure processing of files landed in
-- Object Storage buckets. Buckets, their endpoint URL and their priority order are
-- read from AD_BUCKET_CONFIG.
--
-- Loading: each bucket names its own loader in AD_BUCKET_CONFIG.LOAD_PROCEDURE, called
-- dynamically for every file. The default, LOAD_DEFAULT, loads by file extension.
--
-- Success: after the file is loaded and committed it is MOVED (copied, then deleted from the
-- source) to the archive bucket. If the move fails, the file is already in AD_FILE_LOG so it
-- is never loaded twice; the move is retried at the start of every run for that bucket and
-- each failure is written to AD_FILE_ERROR (type MOVE).
--
-- Failure: the file's work is rolled back and a LOAD row is written to AD_FILE_ERROR. The same
-- file is retried on the next runs. Once it has failed MAX_ATTEMPTS times it is MOVED to the
-- error bucket (type QUARANTINED) and the bucket carries on with the next file. THAT BREAKS
-- THE LOAD ORDER FOR THAT FILE ON PURPOSE. Until then the failing file blocks its bucket so a
-- newer file never overtakes it. If the move to the error bucket itself fails, the bucket
-- stays blocked. Set MAX_ATTEMPTS high for an interface that must never skip a file.
-- Retries are one per job run (15 seconds), so MAX_ATTEMPTS = 3 gives a file about 45 seconds
-- of transient trouble (database or Object Storage unavailable) before it is quarantined.
-- A failure before a file is chosen (for example listing the bucket) blocks the bucket.
--
-- Order: oldest object (Object Storage creation time) first, ties broken by name.
-- Each file is loaded and logged in ONE transaction. Ordering is per bucket, so the other
-- buckets carry on when one is blocked.
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

  -- One row of AD_BUCKET_CONFIG, as the processing routines need it. All URIs end in /o/.
  TYPE t_bucket IS RECORD (
    bucket_uri      VARCHAR2(500),
    load_procedure  VARCHAR2(261),
    archive_uri     VARCHAR2(500),
    error_uri       VARCHAR2(500),
    max_attempts    NUMBER);

  -- Processes at most ONE file per call. Returns TRUE if a file was processed or
  -- quarantined, FALSE if there was nothing to do. Raises when the bucket must stop.
  FUNCTION process_next (p_b IN t_bucket) RETURN BOOLEAN;

  -- Drains one bucket in order; stops (raises) when the bucket is blocked.
  PROCEDURE process_all (p_b IN t_bucket);

  -- Drains the enabled buckets of AD_BUCKET_CONFIG whose JOB_NAME equals p_job_name,
  -- lowest PRIORITY number first. Each scheduler job passes its own name, so adding a
  -- job is a new job plus table updates, with no code change.
  -- A failure stops only that bucket (it is already recorded in AD_FILE_ERROR); the
  -- other buckets of the job still run.
  PROCEDURE process_all_buckets (p_job_name IN VARCHAR2);
END ad_file_persist_pkg;
/

CREATE OR REPLACE PACKAGE BODY ad_file_persist_pkg AS

  c_cred CONSTANT VARCHAR2(30) := 'OCI$RESOURCE_PRINCIPAL';

  -- Autonomous, so the record survives the rollback of the file's load.
  PROCEDURE log_failure (p_bucket_uri VARCHAR2, p_object VARCHAR2,
                         p_created TIMESTAMP WITH TIME ZONE,
                         p_type VARCHAR2, p_err VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO ad_file_error (bucket_uri, object_name, object_created, error_type, error_text)
    VALUES (p_bucket_uri, p_object, p_created, p_type, SUBSTR(p_err, 1, 4000));
    COMMIT;
  END log_failure;

  -- Target object URI in a shared archive or error bucket:
  --   <target uri><source bucket name>/<yyyy-mm-dd of creation>/<file_id>_<object name>
  -- The file id keeps a re-sent file of the same name from overwriting the first. Built only
  -- from values that do not change between retries, so a retried copy lands on the same key.
  FUNCTION target_uri (p_target_base VARCHAR2, p_bucket_uri VARCHAR2, p_file_id NUMBER,
                       p_object VARCHAR2, p_created TIMESTAMP WITH TIME ZONE) RETURN VARCHAR2 IS
  BEGIN
    RETURN RTRIM(p_target_base, '/') || '/'
           || REGEXP_SUBSTR(p_bucket_uri, '/b/([^/]+)/o/', 1, 1, NULL, 1) || '/'
           || TO_CHAR(p_created, 'YYYY-MM-DD') || '/'
           || p_file_id || '_' || p_object;
  END target_uri;

  -- Object Storage has no move: copy to the target, then delete the source. If the copy
  -- fails the source is left alone. Raises on failure.
  PROCEDURE move_object (p_source_uri VARCHAR2, p_target_uri VARCHAR2) IS
  BEGIN
    DBMS_CLOUD.COPY_OBJECT(source_credential_name => c_cred,
                           source_object_uri      => p_source_uri,
                           target_object_uri      => p_target_uri,
                           target_credential_name => c_cred);
    DBMS_CLOUD.DELETE_OBJECT(credential_name => c_cred, object_uri => p_source_uri);
  END move_object;

  -- ---- Archive a loaded file ----------------------------------------------------
  -- Never raises: the file is already loaded and logged. A failure is recorded and the
  -- move is retried on the next run (see archive_loaded).
  PROCEDURE archive_one (p_b t_bucket, p_file_id NUMBER, p_object VARCHAR2,
                         p_created TIMESTAMP WITH TIME ZONE) IS
  BEGIN
    move_object(p_b.bucket_uri || p_object,
                target_uri(p_b.archive_uri, p_b.bucket_uri, p_file_id, p_object, p_created));
  EXCEPTION
    WHEN OTHERS THEN
      log_failure(p_b.bucket_uri, p_object, p_created, 'MOVE',
                  'ARCHIVE FAILED (file already loaded): ' || SQLERRM);
  END archive_one;

  -- Retries archive moves that failed earlier: objects still in the bucket that are already
  -- in AD_FILE_LOG. The creation time must match, so a new file re-sent under the same name
  -- is never archived unloaded.
  PROCEDURE archive_loaded (p_b t_bucket) IS
  BEGIN
    FOR o IN (SELECT l.object_name, l.created, f.file_id
              FROM   DBMS_CLOUD.LIST_OBJECTS(c_cred, p_b.bucket_uri) l
              JOIN   ad_file_log f
                ON   f.bucket_uri     = p_b.bucket_uri
               AND   f.object_name    = l.object_name
               AND   f.object_created = l.created)
    LOOP
      archive_one(p_b, o.file_id, o.object_name, o.created);
    END LOOP;
  END archive_loaded;

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
  FUNCTION process_next (p_b IN t_bucket) RETURN BOOLEAN IS
    l_name     VARCHAR2(1024);
    l_created  TIMESTAMP WITH TIME ZONE;
    l_uri      VARCHAR2(4000);
    l_proc     VARCHAR2(400);
    l_file_id  NUMBER;
    l_read     NUMBER := 0;
    l_loaded   NUMBER := 0;
    l_err      VARCHAR2(4000);
    l_attempts NUMBER;
    l_target   VARCHAR2(4000);
  BEGIN
    BEGIN
      SELECT object_name, created
      INTO   l_name, l_created
      FROM  (SELECT o.object_name, o.created
             FROM   DBMS_CLOUD.LIST_OBJECTS(c_cred, p_b.bucket_uri) o
             WHERE  NOT EXISTS (SELECT 1 FROM ad_file_log f
                                WHERE f.bucket_uri = p_b.bucket_uri
                                AND   f.object_name = o.object_name
                                AND   f.object_created = o.created)
             ORDER  BY o.created, o.object_name)
      WHERE  ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN RETURN FALSE;
    END;

    l_uri := p_b.bucket_uri || l_name;

    -- Reserve the id up front so loaded rows can reference the file.
    l_file_id := ad_file_log_seq.NEXTVAL;

    -- The loader name comes from AD_BUCKET_CONFIG. DBMS_ASSERT rejects anything that is
    -- not a (qualified) SQL name, so the value cannot inject SQL; only table writers can
    -- choose the procedure.
    l_proc := DBMS_ASSERT.QUALIFIED_SQL_NAME(p_b.load_procedure);

    EXECUTE IMMEDIATE 'BEGIN ' || l_proc || '(:1, :2, :3, :4, :5, :6); END;'
      USING IN l_uri, IN l_name, IN l_file_id, IN c_cred, OUT l_read, OUT l_loaded;

    INSERT INTO ad_file_log (file_id, bucket_uri, object_name, object_created, rows_read, rows_loaded)
    VALUES (l_file_id, p_b.bucket_uri, l_name, l_created, l_read, l_loaded);

    COMMIT;   -- rows + log entry together
    archive_one(p_b, l_file_id, l_name, l_created);   -- after the commit; a failure is non-fatal
    RETURN TRUE;
  EXCEPTION
    WHEN OTHERS THEN
      l_err := SQLERRM;
      ROLLBACK;
      log_failure(p_b.bucket_uri, l_name, l_created, 'LOAD', l_err);

      -- No file chosen yet (for example listing failed): nothing to quarantine, stop the bucket.
      IF l_name IS NULL THEN
        RAISE;
      END IF;

      SELECT COUNT(*) INTO l_attempts
      FROM   ad_file_error
      WHERE  bucket_uri = p_b.bucket_uri AND object_name = l_name
      AND    object_created = l_created AND error_type = 'LOAD';

      -- Not out of attempts yet: stop the bucket so a newer file cannot overtake this one.
      IF l_attempts < p_b.max_attempts THEN
        RAISE;
      END IF;

      -- Out of attempts: move the file to the error bucket and carry on with the next file.
      BEGIN
        l_target := target_uri(p_b.error_uri, p_b.bucket_uri, l_file_id, l_name, l_created);
        move_object(l_uri, l_target);
        log_failure(p_b.bucket_uri, l_name, l_created, 'QUARANTINED',
                    'Moved to ' || l_target || ' after ' || l_attempts || ' attempts. Last error: ' || l_err);
        RETURN TRUE;
      EXCEPTION
        WHEN OTHERS THEN
          log_failure(p_b.bucket_uri, l_name, l_created, 'MOVE',
                      'QUARANTINE FAILED, bucket stays blocked: ' || SQLERRM);
          RAISE;
      END;
  END process_next;

  PROCEDURE process_all (p_b IN t_bucket) IS
  BEGIN
    archive_loaded(p_b);   -- retry any earlier failed archive moves first
    WHILE process_next(p_b) LOOP
      NULL;
    END LOOP;
  END process_all;

  -- ---- The enabled buckets assigned to one scheduler job ---------------------
  PROCEDURE process_all_buckets (p_job_name IN VARCHAR2) IS
    l_b t_bucket;
  BEGIN
    FOR b IN (SELECT bucket_uri, load_procedure, archive_uri, error_uri, max_attempts
              FROM   ad_bucket_config
              WHERE  enabled = 'Y'
              AND    job_name = p_job_name
              ORDER  BY priority, bucket_uri)
    LOOP
      BEGIN
        -- RTRIM + '/' so every URI ends in exactly one slash, because object names are
        -- appended to them.
        l_b.bucket_uri     := RTRIM(b.bucket_uri, '/') || '/';
        l_b.load_procedure := b.load_procedure;
        l_b.archive_uri    := RTRIM(b.archive_uri, '/') || '/';
        l_b.error_uri      := RTRIM(b.error_uri, '/') || '/';
        l_b.max_attempts   := b.max_attempts;
        process_all(l_b);
      EXCEPTION
        WHEN OTHERS THEN
          NULL;   -- already recorded in AD_FILE_ERROR; ordering is per bucket, so carry on with the job's other buckets
      END;
    END LOOP;
  END process_all_buckets;

END ad_file_persist_pkg;
/
