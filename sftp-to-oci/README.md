# SFTP to OCI Object Storage to ATP

Ordered, restartable file transfer from SFTP servers into OCI Object Storage buckets,
then ordered persistence into Autonomous Database (ATP) with content filtering.
Full design: [`docs/SFTP_to_OCI_Technical_Specification.docx`](docs/SFTP_to_OCI_Technical_Specification.docx).

All hosts, OCIDs, namespaces and bucket names in this folder are placeholders.
No credentials belong in this repository.

## Layout

| Path | Purpose |
| --- | --- |
| `bin/transfer.sh` | Generic transfer script: remote, folder, pattern, bucket, interval. Oldest-first, one file at a time, stops on first failure |
| `systemd/sftp2oci@.service` | Template unit, one instance per folder/bucket pair |
| `config/rclone.conf.example` | One rclone remote per SFTP server, plus the OCI remote |
| `config/server1-bucket-a.env.example` | Per-pair settings consumed by the unit |
| `iam/policy.example.txt` | Dynamic group and policy statements for the VM and for ATP |
| `atp/00_connect_to_object_storage.sql` | Admin script: enable the resource principal, grants, and connectivity checks for ATP |
| `atp/01_ddl.sql` | `AD_BUCKET_CONFIG`, `AD_FILE_LOG`, `AD_FILE_ERROR`, `AD_FILTER_CONFIG`, staging and sample target tables |
| `atp/02_persist_pkg.sql` | `AD_FILE_PERSIST_PKG`: ordered loader with CSV, JSON and XML filtering examples |
| `atp/03_scheduler_job.sql` | Jobs `AD_PERSIST_FILES_A` and `_B`: each polls its own buckets from `AD_BUCKET_CONFIG` every 15 seconds |
| `tests/` | Stub-rclone behavioural tests for the ordering logic (`bash tests/test_ordering.sh`) |

## Ordering guarantees

- Files are ordered by their modified time on the SFTP server. File names are never used for ordering.
- The folder is listed again before every file and the oldest remaining file is picked, so a file
  arriving mid-run with an older timestamp is handled in its proper place.
- One file at a time; the next starts only after the previous one is uploaded (and deleted in move mode).
- A failed file stops the cycle; the next cycle retries it first. Nothing is skipped.
- In move mode a high-water mark is kept in `/var/lib/sftp2oci`. A file that appears with an older
  timestamp than one already transferred is still transferred, and `ORDER_VIOLATION` is logged. Alert on
  that string.
- The sender writes each file under its final name only when complete and does not preserve source
  timestamps, so modified time reflects arrival.
- Timestamps have one-second precision. Files in the same second have no real order; they are processed in
  name order only to keep the result deterministic.

## Minimum file age (optional, per pair)

Set `MIN_AGE_SECONDS` in a pair's env file to transfer a file only once its modified time is at least
that old. The default `0` transfers immediately, so it can differ per server and folder.

- Files go oldest-first, so if the oldest file is too young every other file is younger still. The cycle
  ends and the file is picked up in the first cycle after it reaches the age. Waiting never breaks order.
- A file still being written keeps a fresh modified time, so this doubles as a "no writes in the last N
  seconds" check.
- A file moves between `MIN_AGE_SECONDS` and `MIN_AGE_SECONDS` plus the polling interval after it appears.
- Age is measured against the VM clock. Keep the VM on NTP; if the SFTP server clock runs ahead, files
  wait longer than intended.

## ATP conventions and buckets

- ATP reads the buckets with its own identity (resource principal), so no keys are stored. The OCI admin
  team creates a dynamic group for the database and a policy allowing list, read and delete on the source buckets and create on the archive and error buckets; the DBA then runs
  `atp/00_connect_to_object_storage.sql`. Full steps are in section 8.1 of the spec.

- Every custom ATP object starts with `AD_` (tables, sequence, package, scheduler job, constraints).
- Buckets are not written into any code or job. They are rows in `AD_BUCKET_CONFIG`
  (`bucket_uri`, `description`, `job_name`, `priority`, `load_procedure`, `archive_uri`, `error_uri`,
  `max_attempts`, `enabled` `Y`/`N`). To add a bucket, insert a row; to pause
  one, set `enabled = 'N'`. The sample rows are disabled until real values are entered.
- `bucket_uri` is the full URI of the bucket, so the endpoint, namespace and bucket all live in the table:
  `https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/`. A missing trailing `/`
  is added. `AD_FILE_LOG` and `AD_FILE_ERROR` record the bucket by this URI.
- `load_procedure` names the procedure that loads each file of that bucket; it is called dynamically, so a
  new file format or target is a new procedure plus one table update. It must follow the contract at the top
  of `AD_FILE_PERSIST_PKG` (file URI, object name, file id, credential in; rows read and loaded out; no
  commit). The default, `AD_FILE_PERSIST_PKG.LOAD_DEFAULT`, loads CSV, JSON and XML by extension.
- `priority` sets the read order: the lowest number is read first, ties go by bucket name.
- `job_name` says which scheduler job processes the bucket. Each job passes its own name to
  `process_all_buckets` and picks only the enabled rows carrying that name, so the work is split across jobs
  in the table. For another job, copy a `CREATE_JOB` block with a new name and point buckets at it; no code
  changes. A bucket has one job only, so jobs never overlap on a bucket and its order holds. A `job_name`
  with no matching job means the bucket is never processed; `03_scheduler_job.sql` has a query to catch it.
- `description` is free text: what the bucket holds and which interface it serves.
- **Success:** after a file is loaded and committed, ATP moves it (copy, then delete) from the bucket to the
  shared archive bucket (`archive_uri`), stored as `<source bucket>/<yyyy-mm-dd>/<file_id>_<object>` so
  integrations sharing the archive never overwrite each other. If the move fails, the file is already in
  `AD_FILE_LOG` so it is not loaded twice; the move is retried at the start of the next run.
- **Failure:** the file's work is rolled back, a `LOAD` row goes to `AD_FILE_ERROR`, and the bucket is blocked
  while the file is retried each run. After `max_attempts` failed attempts (default 3, about 45 seconds at a
  15-second poll) the file is moved to the shared error bucket (`error_uri`), a `QUARANTINED` row is written,
  and the bucket carries on with the next file. **That deliberately skips the load order for that file.**
  Raise `max_attempts` for an interface that must never skip, or if short outages should not quarantine files.
  If the move to the error bucket fails, or the failure happens before a file is chosen (for example listing
  the bucket), the bucket stays blocked. Alert on `QUARANTINED` and `MOVE` rows.
- Within a job the buckets are read in priority order, each drained before the next. A failure stops only
  the bucket it happened in; the job's other buckets carry on.

## Add a new SFTP server

1. Add a `[sftp-serverN]` block to `/etc/rclone/rclone.conf`.
2. Create its SSH key, give the public key to the provider, add its host key to `known_hosts`.
3. Ask the provider to allowlist the NAT gateway IP.
4. Create `/etc/sftp2oci/serverN-bucket-x.env` per folder/bucket pair, then
   `systemctl enable --now sftp2oci@serverN-bucket-x`.

`transfer.sh` and the unit file never change.

## Status

`tests/test_ordering.sh` (21 checks, stub rclone) covers oldest-first order, same-second tie-break, mid-run
arrivals, late-file detection, failure and resume, copy mode, timestamp-over-name precedence and the minimum-age wait. It has not been run
against a real SFTP server or bucket. The SQL is sample code written without a database to test
against: validate it in a non-production ATP before use.
