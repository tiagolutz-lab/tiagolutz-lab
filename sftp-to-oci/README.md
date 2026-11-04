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

## Add a new SFTP server

1. Add a `[sftp-serverN]` block to `/etc/rclone/rclone.conf`.
2. Create its SSH key, give the public key to the provider, add its host key to `known_hosts`.
3. Ask the provider to allowlist the NAT gateway IP.
4. Create `/etc/sftp2oci/serverN-bucket-x.env` per folder/bucket pair, then
   `systemctl enable --now sftp2oci@serverN-bucket-x`.

`transfer.sh` and the unit file never change.

## Status

The shell script and unit follow the design agreed in discussion. The SQL is sample code
written without a database to test against: validate it in a non-production ATP before use.
