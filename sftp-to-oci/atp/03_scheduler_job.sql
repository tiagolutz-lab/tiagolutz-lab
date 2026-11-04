-- =============================================================================
-- 03_scheduler_job.sql
-- Polls one bucket every 15 seconds. DBMS_SCHEDULER does not start a second run
-- of the same job while one is still running, so runs cannot overlap.
-- Create one job per bucket. Replace the placeholders.
-- =============================================================================
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'PERSIST_BUCKET_A',
    job_type        => 'PLSQL_BLOCK',
    job_action      => q'[BEGIN
      file_persist_pkg.process_all(
        'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket-a>/o/',
        '<bucket-a>');
    END;]',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=SECONDLY;INTERVAL=15',
    enabled         => TRUE);
END;
/

-- Alert on new rows in FILE_ERROR, or on a file failing repeatedly:
-- SELECT bucket_name, object_name, COUNT(*) attempts, MAX(failed_at) last_failure
-- FROM   file_error GROUP BY bucket_name, object_name HAVING COUNT(*) >= 3;
