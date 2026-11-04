-- =============================================================================
-- 03_scheduler_job.sql
-- Scheduler jobs that poll the buckets in AD_BUCKET_CONFIG every 15 seconds.
-- Each job passes its own name to AD_FILE_PERSIST_PKG.PROCESS_ALL_BUCKETS and works only
-- on the enabled buckets whose AD_BUCKET_CONFIG.JOB_NAME equals that name. The buckets
-- are therefore split across jobs in the table, not in code.
-- DBMS_SCHEDULER does not start a second run of the same job while one is still
-- running, and a bucket belongs to one job only, so runs cannot overlap on a bucket.
--
-- Two jobs are created below. To add a third (for example AD_PERSIST_FILES_C): copy
-- one CREATE_JOB block, change the job name in JOB_NAME and in the call, and point
-- buckets at it with UPDATE ad_bucket_config SET job_name = 'AD_PERSIST_FILES_C' ...
--
-- Buckets are not named here. To add one:
--   INSERT INTO ad_bucket_config (bucket_uri, description, job_name, priority, load_procedure,
--                                 archive_uri, error_uri, max_attempts)
--   VALUES ('https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/',
--           'What the bucket holds and which interface it serves', 'AD_PERSIST_FILES_A', 10,
--           'AD_FILE_PERSIST_PKG.LOAD_DEFAULT',
--           'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<archive-bucket>/o/',
--           'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<error-bucket>/o/', 3);
--   COMMIT;
-- To move a bucket to another job:
--   UPDATE ad_bucket_config SET job_name = 'AD_PERSIST_FILES_B' WHERE bucket_uri = '<bucket uri>';
--   (takes effect on the job's next run; a run already in progress finishes its bucket first)
-- To pause one: UPDATE ad_bucket_config SET enabled = 'N' WHERE bucket_uri = '<bucket uri>';
-- To change the read order inside a job: UPDATE ad_bucket_config SET priority = <n> WHERE bucket_uri = '<bucket uri>';
--   (lowest number is read first)
-- To use a different loader for a bucket (it must follow the contract at the top of
-- AD_FILE_PERSIST_PKG; no job or package change is needed):
--   UPDATE ad_bucket_config SET load_procedure = 'AD_MY_LOADER_PKG.LOAD_ADS' WHERE bucket_uri = '<bucket uri>';
--
-- Within one job the buckets are processed one after another, in priority order, and
-- each is drained before the next starts. A long file, or a steady stream of new files,
-- in a high-priority bucket delays the lower-priority buckets of the SAME job; buckets
-- on another job are not affected. Use separate jobs for buckets that must not wait
-- for each other.
-- =============================================================================
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'AD_PERSIST_FILES_A',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN ad_file_persist_pkg.process_all_buckets(''AD_PERSIST_FILES_A''); END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=SECONDLY;INTERVAL=15',
    enabled         => TRUE);

  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'AD_PERSIST_FILES_B',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN ad_file_persist_pkg.process_all_buckets(''AD_PERSIST_FILES_B''); END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=SECONDLY;INTERVAL=15',
    enabled         => TRUE);
END;
/

-- Buckets that no job will ever pick up (job name has no scheduler job). Should return no rows:
-- SELECT c.bucket_uri, c.job_name
-- FROM   ad_bucket_config c
-- WHERE  c.enabled = 'Y'
-- AND    NOT EXISTS (SELECT 1 FROM user_scheduler_jobs j WHERE j.job_name = c.job_name);

-- Alert on any QUARANTINED row (a file went to the error bucket and the load order was
-- skipped) and on MOVE rows (archive or quarantine move failing):
-- SELECT bucket_uri, object_name, error_type, failed_at, error_text
-- FROM   ad_file_error WHERE error_type IN ('QUARANTINED', 'MOVE') AND failed_at > SYSTIMESTAMP - INTERVAL '1' DAY;
-- A bucket that is blocked right now has LOAD rows for the same file piling up:
-- SELECT bucket_uri, object_name, COUNT(*) attempts, MAX(failed_at) last_failure
-- FROM   ad_file_error WHERE error_type = 'LOAD' GROUP BY bucket_uri, object_name HAVING COUNT(*) >= 3;
