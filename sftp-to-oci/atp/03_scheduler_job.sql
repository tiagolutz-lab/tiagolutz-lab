-- =============================================================================
-- 03_scheduler_job.sql
-- One job polls every enabled bucket in AD_BUCKET_CONFIG every 15 seconds.
-- DBMS_SCHEDULER does not start a second run of the same job while one is still
-- running, so runs cannot overlap.
--
-- Buckets are not named here. To add one:
--   INSERT INTO ad_bucket_config (bucket_uri, priority, load_procedure)
--   VALUES ('https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/', 10,
--           'AD_FILE_PERSIST_PKG.LOAD_DEFAULT');
--   COMMIT;
-- To pause one: UPDATE ad_bucket_config SET enabled = 'N' WHERE bucket_uri = '<bucket uri>';
-- To change the read order: UPDATE ad_bucket_config SET priority = <n> WHERE bucket_uri = '<bucket uri>';
--   (lowest number is read first)
-- To use a different loader for a bucket (it must follow the contract at the top of
-- AD_FILE_PERSIST_PKG; no job or package change is needed):
--   UPDATE ad_bucket_config SET load_procedure = 'AD_MY_LOADER_PKG.LOAD_ADS' WHERE bucket_uri = '<bucket uri>';
--
-- Buckets are processed one after another within a run, in priority order, and each
-- bucket is drained before the next starts. A long file, or a steady stream of new
-- files, in a high-priority bucket therefore delays the lower-priority ones. If that matters, create a second job and split the
-- buckets between them (for example with an extra column on AD_BUCKET_CONFIG).
-- =============================================================================
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'AD_PERSIST_FILES',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN ad_file_persist_pkg.process_all_buckets; END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=SECONDLY;INTERVAL=15',
    enabled         => TRUE);
END;
/

-- Alert on new rows in AD_FILE_ERROR, or on a file failing repeatedly:
-- SELECT bucket_uri, object_name, COUNT(*) attempts, MAX(failed_at) last_failure
-- FROM   ad_file_error GROUP BY bucket_uri, object_name HAVING COUNT(*) >= 3;
