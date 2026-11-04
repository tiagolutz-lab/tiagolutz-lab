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
| `atp/01_ddl.sql` | Control, error, config, staging and sample target tables |
| `atp/02_persist_pkg.sql` | Ordered loader with CSV, JSON and XML filtering examples |
| `atp/03_scheduler_job.sql` | 15-second polling job per bucket |
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
- SFTP stores no arrival time, so modified time is arrival order only if the sender sets it when the file
  is written and does not preserve the source file's timestamp. Verify this with the sender.
- Timestamps have one-second precision. Files in the same second have no real order; they are processed in
  name order only to keep the result deterministic.

## Add a new SFTP server

1. Add a `[sftp-serverN]` block to `/etc/rclone/rclone.conf`.
2. Create its SSH key, give the public key to the provider, add its host key to `known_hosts`.
3. Ask the provider to allowlist the NAT gateway IP.
4. Create `/etc/sftp2oci/serverN-bucket-x.env` per folder/bucket pair, then
   `systemctl enable --now sftp2oci@serverN-bucket-x`.

`transfer.sh` and the unit file never change.

## Status

`tests/test_ordering.sh` (13 checks, stub rclone) covers oldest-first order, same-second tie-break, mid-run
arrivals, late-file detection, failure and resume, copy mode and timestamp-over-name precedence. It has not been run
against a real SFTP server or bucket. The SQL is sample code written without a database to test
against: validate it in a non-production ATP before use.
