#!/usr/bin/env bash
# Minimal fake rclone for testing transfer.sh without SFTP or OCI.
#   <remote>:<path>   -> $FAKE_SFTP/<path>
#   oci:<bucket>/<x>  -> $FAKE_OCI/<bucket>/<x>
# Supports: lsf, moveto, copyto. Extra env:
#   FAKE_FAIL=<name>   make the transfer of that file fail
#   FAKE_HOOK=<script> run after each successful transfer with the file name
sub="$1"; shift
loc() { case "$1" in oci:*) echo "$FAKE_OCI/${1#oci:}";; *:*) echo "$FAKE_SFTP/${1#*:}";; esac; }
case "$sub" in
  lsf)
    dir=$(loc "$1"); shift
    pat=""
    while [ $# -gt 0 ]; do
      case "$1" in --include) pat="$2"; shift;; esac
      shift
    done
    for f in "$dir"/$pat; do
      [ -f "$f" ] || continue
      printf '%s|%s\n' "$(date -d "@$(stat -c %Y "$f")" '+%F %T')" "$(basename "$f")"
    done ;;
  moveto|copyto)
    s=$(loc "$1"); d=$(loc "$2"); n=$(basename "$s")
    if [ -n "${FAKE_FAIL:-}" ] && [ "$n" = "$FAKE_FAIL" ]; then echo "simulated failure: $n" >&2; exit 1; fi
    mkdir -p "$(dirname "$d")"
    cp -p "$s" "$d"
    echo "$n" >> "$FAKE_OCI/order.log"
    [ "$sub" = moveto ] && rm -f "$s"
    if [ -n "${FAKE_HOOK:-}" ] && [ -x "$FAKE_HOOK" ]; then "$FAKE_HOOK" "$n"; fi ;;
  *) echo "stub: unsupported $sub" >&2; exit 2 ;;
esac
