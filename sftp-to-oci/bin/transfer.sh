#!/usr/bin/env bash
# transfer.sh - move files from one SFTP folder to one OCI Object Storage bucket,
# strictly oldest-first by SFTP modified time, one file at a time, stopping at the
# first failure.
#
# Usage:
#   transfer.sh <rclone_remote> <sftp_folder> <file_pattern> <bucket> [interval_seconds]
#
# Example:
#   transfer.sh sftp-server1 /outbound/a 'ad_*.xml' bucket-a 15
#
# Ordering
#   * The order key is the file's modified time on the SFTP server. File names are NOT
#     used for ordering. The sender writes each file under its final name only when it is
#     complete and does not preserve source timestamps, so modified time reflects arrival.
#   * SFTP timestamps have one-second precision. Files sharing the same second have no
#     real order; they are processed in name order purely so the result is deterministic.
#   * The folder is listed again before EVERY file, and the oldest remaining file is
#     picked each time. A file that arrives mid-run with an older timestamp is therefore
#     picked next, not after the whole batch.
#   * One file at a time; the next starts only after the previous one is uploaded
#     (and, in move mode, deleted from SFTP).
#   * A failed file stops the cycle. The next cycle retries that same file first.
#   * In move mode a high-water mark records the newest timestamp already transferred.
#     If a file later shows up with an OLDER timestamp (it arrived late, or the sender
#     preserved an old timestamp), the script logs ORDER_VIOLATION so it can be alerted
#     on. The file is still transferred: blocking forever would stall the pair.
#
# Environment (all optional):
#   RCLONE_MODE   move (default) or copy. Use copy during the parallel-run phase.
#   PAIR_ID       unique name for this pair; used for lock, log and state file names
#   RCLONE_CONF   path to rclone.conf (default /etc/rclone/rclone.conf)
#   LOG_DIR       log directory (default /var/log/rclone)
#   LOCK_DIR      lock directory (default /tmp)
#   STATE_DIR     high-water-mark directory (default /var/lib/sftp2oci)
#
# interval_seconds = 0 (default) runs one cycle and exits. Anything greater loops forever.
set -uo pipefail
export LC_ALL=C   # byte-wise, locale-independent sorting and comparison

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
STATE_DIR="${STATE_DIR:-/var/lib/sftp2oci}"

case "$MODE" in
  move|copy) ;;
  *) echo "RCLONE_MODE must be move or copy, got: $MODE" >&2; exit 2 ;;
esac

mkdir -p "$LOG_DIR"

# One instance per pair; a second start exits immediately.
exec 9>"${LOCK_DIR}/sftp2oci-${ID}.lock"
flock -n 9 || { echo "already running for $ID"; exit 0; }

log() { echo "$(date -Is) [$ID] $*" | tee -a "$LOG_DIR/${ID}.log"; }

# High-water mark: only meaningful in move mode, where transferred files leave the
# folder (in copy mode they stay, so older files are legitimately seen every cycle).
HWM_FILE=""
if [ "$MODE" = move ]; then
  if mkdir -p "$STATE_DIR" 2>/dev/null; then
    HWM_FILE="${STATE_DIR}/${ID}.hwm"
  else
    log "WARNING cannot create $STATE_DIR; late-file detection disabled"
  fi
fi

# Modified time from a "modtime|name" line.
mtime_of() { printf '%s' "${1%%|*}"; }

# Prints the next file as "modtime|name" (oldest first, skipping names already handled
# in this cycle), or nothing when there is none. Non-zero if the listing fails.
next_file() {
  local list sorted line n
  list=$(rclone lsf "${REMOTE}:${SRC}" \
      --config "$RCLONE_CONF" \
      --files-only --max-depth 1 \
      --include "$PATTERN" \
      --format "tp" --separator "|") || return 1
  [ -z "$list" ] && return 0

  # Oldest first. Name is only a tie-break for identical one-second timestamps.
  sorted=$(sort -t'|' -k1,1 -k2 <<< "$list")

  while IFS= read -r line; do
    n="${line#*|}"
    [ -n "${seen[$n]:-}" ] && continue
    printf '%s\n' "$line"
    return 0
  done <<< "$sorted"
}

# Flag a file whose timestamp is older than one already transferred.
check_late() {
  [ -n "$HWM_FILE" ] && [ -s "$HWM_FILE" ] || return 0
  local hwm; hwm=$(<"$HWM_FILE")
  if [[ "$(mtime_of "$1")" < "$(mtime_of "$hwm")" ]]; then
    log "ORDER_VIOLATION '${1#*|}' (modtime $(mtime_of "$1")) is older than the last transferred '${hwm#*|}' (modtime $(mtime_of "$hwm")); it arrived late. Transferring anyway."
  fi
}

# Keep the newest timestamp transferred so far.
record_hwm() {
  [ -n "$HWM_FILE" ] || return 0
  local cur=""
  [ -s "$HWM_FILE" ] && cur=$(<"$HWM_FILE")
  if [ -z "$cur" ] || ! [[ "$(mtime_of "$1")" < "$(mtime_of "$cur")" ]]; then
    printf '%s\n' "$1" > "$HWM_FILE"
  fi
}

run_once() {
  local -A seen=()
  local line name

  while true; do
    line=$(next_file) || return 1
    [ -z "$line" ] && return 0
    name="${line#*|}"

    check_late "$line"
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

    seen["$name"]=1   # copy mode leaves the file in place; do not pick it again this cycle
    record_hwm "$line"
    log "DONE $name"
  done
}

while true; do
  run_once || log "CYCLE FAILED ${REMOTE}:${SRC} -> ${BUCKET}"
  [ "$INTERVAL" -gt 0 ] || break
  sleep "$INTERVAL"
done
