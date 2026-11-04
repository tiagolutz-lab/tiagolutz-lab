#!/usr/bin/env bash
# transfer.sh - move files from one SFTP folder to one OCI Object Storage bucket,
# strictly oldest-first, one file at a time, stopping at the first failure.
#
# Usage:
#   transfer.sh <rclone_remote> <sftp_folder> <file_pattern> <bucket> [interval_seconds]
#
# Example:
#   transfer.sh sftp-server1 /outbound/a 'ad_*.xml' bucket-a 15
#
# Environment (all optional):
#   RCLONE_MODE   move (default) or copy. Use copy during the parallel-run phase.
#   PAIR_ID       unique name for this pair; used for lock and log file names.
#   RCLONE_CONF   path to rclone.conf (default /etc/rclone/rclone.conf)
#   LOG_DIR       log directory (default /var/log/rclone)
#   LOCK_DIR      lock directory (default /tmp)
#
# interval_seconds = 0 (default) runs one cycle and exits. Anything greater loops forever.
set -uo pipefail

REMOTE="${1:?rclone remote, e.g. sftp-server1}"
SRC="${2:?sftp folder}"
PATTERN="${3:?file pattern, e.g. ad_*.xml}"
BUCKET="${4:?bucket}"
INTERVAL="${5:-0}"

MODE="${RCLONE_MODE:-move}"
ID="${PAIR_ID:-${REMOTE}-${BUCKET}}"
RCLONE_CONF="${RCLONE_CONF:-/etc/rclone/rclone.conf}"
LOG_DIR="${LOG_DIR:-/var/log/rclone}"
LOCK_DIR="${LOCK_DIR:-/tmp}"

case "$MODE" in
  move|copy) ;;
  *) echo "RCLONE_MODE must be move or copy, got: $MODE" >&2; exit 2 ;;
esac

mkdir -p "$LOG_DIR"

# One instance per pair; a second start exits immediately.
exec 9>"${LOCK_DIR}/sftp2oci-${ID}.lock"
flock -n 9 || { echo "already running for $ID"; exit 0; }

log() { echo "$(date -Is) [$ID] $*" | tee -a "$LOG_DIR/${ID}.log"; }

run_once() {
  local list line name

  # Matching files as "modtime|name", oldest first (ties broken by name).
  list=$(rclone lsf "${REMOTE}:${SRC}" \
      --config "$RCLONE_CONF" \
      --files-only --max-depth 1 \
      --include "$PATTERN" \
      --format "tp" --separator "|" | sort -t'|' -k1,1 -k2,2) || return 1

  [ -z "$list" ] && return 0

  while IFS= read -r line; do
    name="${line#*|}"
    log "START $name"
    rclone "${MODE}to" "${REMOTE}:${SRC}/${name}" "oci:${BUCKET}/${name}" \
      --config "$RCLONE_CONF" \
      --transfers 1 \
      --oos-upload-cutoff 200M \
      --oos-chunk-size 128M \
      --oos-upload-concurrency 4 \
      --retries 5 --low-level-retries 20 \
      --log-level INFO --log-file "$LOG_DIR/${ID}.rclone.log" \
      || { log "FAILED $name - stopping cycle to keep order"; return 1; }
    log "DONE $name"
  done <<< "$list"
}

while true; do
  run_once || log "CYCLE FAILED ${REMOTE}:${SRC} -> ${BUCKET}"
  [ "$INTERVAL" -gt 0 ] || break
  sleep "$INTERVAL"
done
