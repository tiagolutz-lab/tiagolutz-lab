-- =============================================================================
-- 03_scheduler_job.sql
-- One job polls every enabled bucket in AD_BUCKET_CONFIG every 15 seconds.
-- DBMS_SCHEDULER does not start a second run of the same job while one is still
-- running, so runs cannot overlap.
--
-- Buckets are not named here. To add one:
--   INSERT INTO ad_bucket_config (bucket_name, namespace, region) VALUES ('<bucket>', '<namespace>', '<region>');
--   COMMIT;
-- To pause one: UPDATE ad_bucket_config SET enabled = 'N' WHERE bucket_name = '<bucket>';
--
-- Buckets are processed one after another within a run, so a long file in one
-- bucket delays the others. If that matters, create a second job and split the
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
-- SELECT bucket_name, object_name, COUNT(*) attempts, MAX(failed_at) last_failure
-- FROM   ad_file_error GROUP BY bucket_name, object_name HAVING COUNT(*) >= 3;
