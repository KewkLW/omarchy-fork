#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

TMPDIR=$(mktemp -d)
dummy_pids=()
cleanup() {
  local pid
  for pid in "${dummy_pids[@]}"; do
    kill -CONT "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
  done
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

mkdir -p "$TMPDIR/bin"
SYSTEMCTL_LOG="$TMPDIR/systemctl-log"
NOTIFY_LOG="$TMPDIR/notify-log"

cat >"$TMPDIR/bin/systemctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
SH

cat >"$TMPDIR/bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$NOTIFY_LOG"
SH

# The user journal answers a follow with JOURNAL_USER, the system journal any
# other query with JOURNAL_SYSTEM. Never the real journals.
cat >"$TMPDIR/bin/journalctl" <<'SH'
#!/bin/bash
if [[ " $* " == *" --user "* ]]; then
  [[ -n ${JOURNAL_USER:-} ]] && printf '%s\n' "$JOURNAL_USER"
else
  [[ -n ${JOURNAL_SYSTEM:-} ]] && printf '%s\n' "$JOURNAL_SYSTEM"
fi
exit 0
SH

chmod +x "$TMPDIR/bin/"*

test_home="$TMPDIR/home"
flag="$test_home/.local/state/omarchy/toggles/memory-watch-on"
state="$test_home/.local/state/omarchy/memory-watch"
installed_unit="$test_home/.config/systemd/user/omarchy-memory-watch.service"

run() {
  PATH="$TMPDIR/bin:$ROOT/bin:$PATH" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" NOTIFY_LOG="$NOTIFY_LOG" \
    HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" OMARCHY_PATH="$ROOT" "$@"
}

# Toggle: opt-in, so the first toggle turns it on.
run "$ROOT/bin/omarchy-toggle-memory-watch"
[[ -f $flag ]] || fail "the first memory watchdog toggle turns it on"
cmp -s "$ROOT/default/systemd/user/omarchy-memory-watch.service" "$installed_unit" ||
  fail "turning the memory watchdog on installs its unit, which no package ships"
grep -Fqx -- "--user enable --now omarchy-memory-watch.service" "$SYSTEMCTL_LOG" ||
  fail "enabling the memory watchdog starts it now and at every login"
pass "memory watchdog toggle installs and enables the watcher"

: >"$SYSTEMCTL_LOG"
run "$ROOT/bin/omarchy-toggle-memory-watch"
[[ ! -f $flag ]] || fail "the second memory watchdog toggle turns it off"
grep -Fqx -- "--user disable --now omarchy-memory-watch.service" "$SYSTEMCTL_LOG" ||
  fail "disabling the memory watchdog stops it now and at every login"
[[ ! -e $installed_unit ]] || fail "turning the memory watchdog off removes the unit it installed"
pass "memory watchdog toggle disables and removes the watcher"

service="$ROOT/default/systemd/user/omarchy-memory-watch.service"
grep -Fx 'ConditionEnvironment=OMARCHY_PATH' "$service" >/dev/null ||
  fail "the memory watchdog waits for OMARCHY_PATH, which the commands it runs need"
grep -Fx 'ConditionPathExists=%h/.local/state/omarchy/toggles/memory-watch-on' "$service" >/dev/null ||
  fail "the memory watchdog stays opt-in even when its unit is enabled"
grep -Fx 'Slice=session.slice' "$service" >/dev/null ||
  fail "the memory watchdog runs in app.slice, where systemd-oomd can kill it before it reports anything"
pass "memory watchdog unit is opt-in and out of systemd-oomd's reach"

# Fake readings: swap 55% (past the 50% warning, short of anything later and
# of oomd's 90%), RAM 82% used, past the warning's 80%, no stall.
fake="$TMPDIR/fake"
mkdir -p "$fake"
cat >"$fake/meminfo" <<'EOF'
MemTotal:        1000000 kB
MemAvailable:     180000 kB
SwapTotal:       1000000 kB
SwapFree:         450000 kB
EOF
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' >"$fake/pressure"

watch() {
  : >"$NOTIFY_LOG"
  # Nothing the watcher could act on outside this test is ever picked.
  run env OMARCHY_MEMORY_MEMINFO="$fake/meminfo" OMARCHY_MEMORY_PRESSURE="$fake/pressure" \
    OMARCHY_MEMORY_APP_PRESSURE="$fake/app-pressure" OMARCHY_MEMORY_INTERVAL=0.2 \
    OMARCHY_MEMORY_ONLY='^omarchy-memtest-nothing$' "$@" \
    timeout 3 "$ROOT/bin/omarchy-memory-watch" 2>/dev/null || true
  sleep 0.3
}

watch
grep -Fq 'Memory is running out' "$NOTIFY_LOG" ||
  fail "swap past the warning line raises a toast before oomd's 90%" "$(cat "$NOTIFY_LOG")"
grep -Fq 'Swap 55% and RAM 82% used; systemd-oomd kills an app once both pass 90%.' "$NOTIFY_LOG" ||
  fail "the warning says how close swap and RAM are to oomd's line, which needs both" "$(cat "$NOTIFY_LOG")"
[[ -s $state/last-top.json ]] || fail "the watcher keeps what memory looked like, to name a later kill"
pass "memory watchdog warns as swap nears oomd's line"

# app.slice stalling counts even when the system as a whole does not.
printf 'MemTotal: 1000000 kB\nMemAvailable: 50000 kB\nSwapTotal: 1000000 kB\nSwapFree: 1000000 kB\n' >"$fake/meminfo"
printf 'some avg10=30.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=25.00 avg60=0.00 avg300=0.00 total=0\n' >"$fake/app-pressure"
watch
grep -Fq 'stalling (25%)' "$NOTIFY_LOG" ||
  fail "app.slice's own stall, the one oomd reads, raises the warning" "$(cat "$NOTIFY_LOG")"
pass "memory watchdog warns on app.slice pressure"

printf 'MemTotal: 1000000 kB\nMemAvailable: 900000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' >"$fake/meminfo"
rm -f "$fake/app-pressure"
watch
[[ ! -s $NOTIFY_LOG ]] || fail "plenty of memory raises no toast" "$(cat "$NOTIFY_LOG")"
pass "memory watchdog stays quiet with memory to spare"

# Swap alone raises nothing: zram is sized to RAM, so it is often half used or
# more while RAM is fine.
printf 'MemTotal: 1000000 kB\nMemAvailable: 500000 kB\nSwapTotal: 1000000 kB\nSwapFree: 100000 kB\n' >"$fake/meminfo"
watch
[[ ! -s $NOTIFY_LOG ]] || fail "swap 90% used with RAM half free raises no toast" "$(cat "$NOTIFY_LOG")"
pass "memory watchdog ignores swap while RAM is fine"

# After a kill, the toast names the app from what the watcher last saw.
unit="app-Hyprland-org.chromium.Chromium@3f2a.scope"
printf '[{"unit":"%s","leader":"chromium","total_mb":9000},{"unit":"%s","leader":"chromium-helper","total_mb":10}]\n' \
  "$unit" "$unit" >"$state/last-top.json"
: >"$NOTIFY_LOG"
run env JOURNAL_USER="{\"USER_UNIT\":\"$unit\",\"N_PROCESSES\":\"12\"}" \
  JOURNAL_SYSTEM="Killed /user.slice/user-1000.slice/user@1000.service/app.slice/$unit due to memory pressure for /user.slice/user-1000.slice/user@1000.service/app.slice being 63.00% > 50.00% for > 20s with reclaim activity" \
  "$ROOT/bin/omarchy-memory-oomd-kills"
grep -Fq 'systemd-oomd killed chromium (9000M)' "$NOTIFY_LOG" ||
  fail "an oomd kill is named after the app the watcher last saw in that scope" "$(cat "$NOTIFY_LOG")"
grep -Fq "12 processes in $unit. It stalled on memory over oomd's 50% for 20s." "$NOTIFY_LOG" ||
  fail "an oomd kill says how many processes went and why" "$(cat "$NOTIFY_LOG")"
pass "memory watchdog names what oomd killed and why"

# Without a snapshot or a readable system journal, it still names the scope.
rm -f "$state/last-top.json"
: >"$NOTIFY_LOG"
run env JOURNAL_USER="{\"USER_UNIT\":\"$unit\",\"N_PROCESSES\":\"3\"}" "$ROOT/bin/omarchy-memory-oomd-kills"
grep -Fq 'systemd-oomd killed org.chromium.Chromium' "$NOTIFY_LOG" ||
  fail "an oomd kill with nothing remembered is named after its scope" "$(cat "$NOTIFY_LOG")"
grep -Fq 'sudo journalctl -u systemd-oomd' "$NOTIFY_LOG" ||
  fail "an unreadable system journal is said, not guessed around" "$(cat "$NOTIFY_LOG")"
pass "memory watchdog names an oomd kill from the scope alone"

# A scope name is systemd-escaped and may end in a random hex suffix.
: >"$NOTIFY_LOG"
run env JOURNAL_USER='{"USER_UNIT":"app-Hyprland-my\\x2dapp-1a2b3c.scope","N_PROCESSES":"1"}' \
  "$ROOT/bin/omarchy-memory-oomd-kills"
grep -Fq 'systemd-oomd killed my-app' "$NOTIFY_LOG" ||
  fail "an oomd kill is named after the unescaped app, without the scope's suffix" "$(cat "$NOTIFY_LOG")"
pass "memory watchdog unescapes the scope it names"

# omarchy memory top finds a process group of this user's.
setsid bash -c 'exec -a omarchy-memtest-dummy sleep 300' &
dummy_pids+=($!)
sleep 0.2
run "$ROOT/bin/omarchy-memory-top" --json | jq -e --argjson pid "${dummy_pids[0]}" \
  'any(.[]; .pids == [$pid] and .leader == "sleep")' >/dev/null ||
  fail "memory top lists a process group with its pids"
pass "memory top lists process groups"
