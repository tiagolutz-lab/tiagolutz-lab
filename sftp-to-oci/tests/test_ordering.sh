#!/usr/bin/env bash
# Behavioural tests for bin/transfer.sh using tests/rclone-stub.sh.
# Run: bash sftp-to-oci/tests/test_ordering.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../bin/transfer.sh"
pass=0; fail=0

setup() {                       # fresh sandbox per test
  T=$(mktemp -d)
  export FAKE_SFTP="$T/sftp" FAKE_OCI="$T/oci" PATH="$T/bin:$PATH"
  export LOG_DIR="$T/log" LOCK_DIR="$T/lock" STATE_DIR="$T/state" RCLONE_CONF=/dev/null
  mkdir -p "$FAKE_SFTP/in" "$FAKE_OCI" "$T/bin" "$LOCK_DIR"
  cp "$HERE/rclone-stub.sh" "$T/bin/rclone"; chmod +x "$T/bin/rclone"
  unset FAKE_FAIL FAKE_HOOK RCLONE_MODE ORDER_KEY
}
mk() { : > "$FAKE_SFTP/in/$1"; touch -d "2026-11-04 10:00:$2" "$FAKE_SFTP/in/$1"; }   # name, seconds
order() { [ -f "$FAKE_OCI/order.log" ] && paste -sd' ' "$FAKE_OCI/order.log" || echo "(none)"; }
run() { PAIR_ID=t timeout 30 bash "$SCRIPT" srv /in 'ad_*.xml' bkt 0 >"$T/out.txt" 2>&1; }
check() {                        # description, expected, actual
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS  $1"; else fail=$((fail+1)); echo "FAIL  $1"; echo "      expected: $2"; echo "      actual:   $3"; fi
}

# 1. Oldest first; equal timestamps tie-break by name; non-matching files untouched
setup
mk ad_c.xml 03; mk ad_a.xml 01; mk ad_b2.xml 02; mk ad_b1.xml 02; mk x.txt 00; mk ad_d.tmp 00
run
check "oldest-first with name tie-break" "ad_a.xml ad_b1.xml ad_b2.xml ad_c.xml" "$(order)"
check "non-matching files left on SFTP" "ad_d.tmp x.txt" "$(ls "$FAKE_SFTP/in" | paste -sd' ')"

# 2. Older file arriving mid-run (newer than the high-water mark) is picked next
setup
mk ad_a.xml 01; mk ad_b.xml 03; mk ad_c.xml 05
cat > "$T/hook.sh" <<H
#!/usr/bin/env bash
if [ "\$1" = ad_a.xml ] && [ ! -e "$T/hooked" ]; then touch "$T/hooked"; : > "$FAKE_SFTP/in/ad_late.xml"; touch -d "2026-11-04 10:00:02" "$FAKE_SFTP/in/ad_late.xml"; fi
H
chmod +x "$T/hook.sh"; export FAKE_HOOK="$T/hook.sh"
run
check "mid-run arrival is re-sorted into place" "ad_a.xml ad_late.xml ad_b.xml ad_c.xml" "$(order)"
check "no false ORDER_VIOLATION" "0" "$(grep -c ORDER_VIOLATION "$T/out.txt")"

# 3. File arriving late with a timestamp older than one already transferred is flagged
setup
mk ad_a.xml 01; mk ad_b.xml 03; mk ad_c.xml 05
cat > "$T/hook.sh" <<H
#!/usr/bin/env bash
if [ "\$1" = ad_b.xml ] && [ ! -e "$T/hooked" ]; then touch "$T/hooked"; : > "$FAKE_SFTP/in/ad_old.xml"; touch -d "2026-11-04 10:00:00" "$FAKE_SFTP/in/ad_old.xml"; fi
H
chmod +x "$T/hook.sh"; export FAKE_HOOK="$T/hook.sh"
run
check "late old file is still transferred" "ad_a.xml ad_b.xml ad_old.xml ad_c.xml" "$(order)"
check "late old file logs ORDER_VIOLATION" "1" "$(grep -c "ORDER_VIOLATION 'ad_old.xml'" "$T/out.txt")"

# 4. Failure stops the cycle; next run resumes at the failed file, nothing skipped
setup
mk ad_a.xml 01; mk ad_b.xml 02; mk ad_c.xml 03
FAKE_FAIL=ad_b.xml run
check "failure: only the older file moved" "ad_a.xml" "$(order)"
check "failure: failed and newer files stay on SFTP" "ad_b.xml ad_c.xml" "$(ls "$FAKE_SFTP/in" | paste -sd' ')"
check "failure is logged" "1" "$(grep -c 'FAILED ad_b.xml' "$T/out.txt")"
run
check "rerun resumes in order with no skips" "ad_a.xml ad_b.xml ad_c.xml" "$(order)"

# 5. Copy mode terminates (no endless re-pick) and leaves sources in place
setup
mk ad_a.xml 01; mk ad_b.xml 02; mk ad_c.xml 03
RCLONE_MODE=copy run
check "copy mode: ordered and terminates" "ad_a.xml ad_b.xml ad_c.xml" "$(order)"
check "copy mode: sources kept" "ad_a.xml ad_b.xml ad_c.xml" "$(ls "$FAKE_SFTP/in" | paste -sd' ')"

# 6. ORDER_KEY=name sorts by file name, ignoring modified time
setup
mk ad_0003.xml 01; mk ad_0001.xml 09; mk ad_0002.xml 05
ORDER_KEY=name run
check "name ordering ignores mtime" "ad_0001.xml ad_0002.xml ad_0003.xml" "$(order)"

# 7. Bad ORDER_KEY is rejected
setup
ORDER_KEY=bogus run; rc=$?
check "invalid ORDER_KEY exits 2" "2" "$rc"

echo; echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
