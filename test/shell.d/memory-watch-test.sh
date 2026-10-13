#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

TMPDIR=$(mktemp -d)
dummy_pids=()
cleanup() {
  local pid
  for pid in "${dummy_pids[@]}"; do
    # Some have exited already, and errexit still holds in this trap.
    kill -CONT "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

mkdir -p "$TMPDIR/bin"
SYSTEMCTL_LOG="$TMPDIR/systemctl-log"
NOTIFY_LOG="$TMPDIR/notify-log"
SYSTEMD_RUN_LOG="$TMPDIR/systemd-run-log"

# No responder unit is ever running here, so the watcher would start one.
cat >"$TMPDIR/bin/systemctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
[[ $* == *is-active* ]] && exit 3
exit 0
SH

# Never a real agent: record what would have started.
cat >"$TMPDIR/bin/systemd-run" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$SYSTEMD_RUN_LOG"
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
    SYSTEMD_RUN_LOG="$SYSTEMD_RUN_LOG" \
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

# The brake pauses a whole group when nothing in it is protected.
# Its own process group, like a job started from a terminal or an agent's shell.
dummy_pid=${dummy_pids[0]}
picked=$(OMARCHY_MEMORY_ONLY=omarchy-memtest-dummy run "$ROOT/bin/omarchy-memory-top" --pick 0) ||
  fail "the brake can pick an unprotected process group"
[[ $picked == *$'\t'"$dummy_pid"$'\t'* ]] || fail "the brake picks the dummy's own pids, got: $picked"
pass "memory brake picks an unprotected group"

if OMARCHY_MEMORY_ONLY=omarchy-memtest-dummy OMARCHY_MEMORY_PROTECT='^sleep$' run "$ROOT/bin/omarchy-memory-top" --pick 0 >/dev/null; then
  fail "the brake never picks a protected process"
fi
pass "memory brake skips protected processes"

# Protection is per process: in a group led by a protected process (Hyprland,
# with everything it started without a launcher in its pgid), the brake takes
# the unprotected child and never the protected leader.
cp "$(command -v bash)" "$TMPDIR/memtest-shield"
cp "$(command -v sleep)" "$TMPDIR/memtest-child"
setsid "$TMPDIR/memtest-shield" -c "\"$TMPDIR/memtest-child\" 301 & \"$TMPDIR/memtest-child\" 302 & wait" &
shield_pid=$!
dummy_pids+=("$shield_pid")
sleep 0.3
child_pids=$(pgrep -g "$shield_pid" -x memtest-child | sort -n | paste -sd,)
dummy_pids+=(${child_pids//,/ })
[[ $child_pids == *,* ]] || fail "the protected group's children started" "$child_pids"
picked=$(OMARCHY_MEMORY_ONLY=memtest- OMARCHY_MEMORY_PROTECT='^memtest-shield$' \
  run "$ROOT/bin/omarchy-memory-top" --pick 0) ||
  fail "the brake picks an unprotected process inside a protected group"
IFS=$'\t' read -r key _ name pids _ <<<"$picked"
[[ $name == memtest-child && $pids =~ ^[0-9]+$ && ,$child_pids, == *,$pids,* ]] ||
  fail "the brake takes one unprotected child of a protected group, got: $picked"
[[ $key == *"#$shield_pid@$pids" ]] || fail "the brake records which tree inside the group it took, got: $key"
[[ ,$pids, != *,$shield_pid,* ]] || fail "the brake never pauses the protected leader"
pass "memory brake protects per process, not per group"

start_time() {
  local stat
  stat=$(<"/proc/$1/stat")
  stat=${stat##*) }
  read -ra stat <<<"$stat"
  echo "${stat[19]}"
}

proc_state() {
  awk '{ print $3 }' "/proc/$1/stat"
}

# A terminal's foreground job is never paused whole: the shell would take the
# terminal back, and the job would be left in the background after a resume.
# The name comes from the environment, so the python parent's own cmdline
# never matches it.
MEMTEST_NAME=omarchy-memtest-fg python3 -c '
import os, pty, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp("sleep", [os.environ["MEMTEST_NAME"], "300"])
print(pid, flush=True)
time.sleep(300)
' >"$TMPDIR/fg-pid" &
dummy_pids+=($!)
sleep 0.5
fg_pid=$(<"$TMPDIR/fg-pid")
dummy_pids+=("$fg_pid")
run "$ROOT/bin/omarchy-memory-top" --json | jq -e --argjson pid "$fg_pid" \
  'any(.[]; .pids == [$pid] and .foreground)' >/dev/null ||
  fail "memory top sees the dummy as a terminal's foreground job"
if picked=$(OMARCHY_MEMORY_ONLY=omarchy-memtest-fg run "$ROOT/bin/omarchy-memory-top" --pick 0); then
  fail "the brake never pauses a terminal's foreground job" "$picked"
fi
pass "memory brake leaves a terminal's foreground job alone"

# Resume sends SIGCONT to exactly what the brake recorded.
kill -STOP "$dummy_pid"
mkdir -p "$state"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "2026-01-01 00:00:00" brake "test#$dummy_pid" 1 sleep "$dummy_pid" \
  "$(start_time "$dummy_pid")" >"$state/frozen.tsv"

if OMARCHY_MEMORY_ONLY=omarchy-memtest-dummy run "$ROOT/bin/omarchy-memory-top" --pick 0 >/dev/null; then
  fail "the brake doesn't pick a group it already paused"
fi
pass "memory brake skips stopped groups"

run "$ROOT/bin/omarchy-memory-resume" sleep >/dev/null
sleep 0.2
[[ $(proc_state "$dummy_pid") != "T" ]] || fail "resume continues the paused group"
[[ ! -s $state/frozen.tsv ]] || fail "resume clears what it resumed from frozen.tsv"
pass "memory resume continues paused groups"

# A pid whose start time no longer matches is someone else's now.
kill -STOP "$dummy_pid"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "2026-01-01 00:00:00" brake "test#$dummy_pid" 1 sleep "$dummy_pid" 1 >"$state/frozen.tsv"
run "$ROOT/bin/omarchy-memory-resume" >/dev/null
sleep 0.2
[[ $(proc_state "$dummy_pid") == "T" ]] || fail "resume never signals a pid that has been reused"
kill -CONT "$dummy_pid"
pass "memory resume checks each process's start time"

# Swap alone never brakes: zram is sized to RAM, so half of it or more in use
# is routine while RAM is fine.
printf 'MemTotal: 1000000 kB\nMemAvailable: 500000 kB\nSwapTotal: 1000000 kB\nSwapFree: 100000 kB\n' >"$fake/meminfo"
: >"$state/frozen.tsv"
watch OMARCHY_MEMORY_ONLY=omarchy-memtest-dummy OMARCHY_MEMORY_BRAKE_MIN_MB=0
[[ $(proc_state "$dummy_pid") != "T" ]] || fail "swap 90% used with RAM half free pauses nothing"
! grep -Fq 'Memory brake' "$NOTIFY_LOG" || fail "swap with RAM to spare raises no brake toast" "$(cat "$NOTIFY_LOG")"
pass "memory brake ignores swap while RAM is fine"

# Swap and RAM both past the brake lines pause one group straight away, short
# of oomd's 90% and 90%. A second dummy stays running: while the first is
# still paused, the brake pauses nothing else, even with no gap between tries.
setsid bash -c 'exec -a omarchy-memtest-dummy2 sleep 300' &
dummy2_pid=$!
dummy_pids+=("$dummy2_pid")
sleep 0.2
printf 'MemTotal: 1000000 kB\nMemAvailable: 120000 kB\nSwapTotal: 1000000 kB\nSwapFree: 200000 kB\n' >"$fake/meminfo"
watch OMARCHY_MEMORY_ONLY=omarchy-memtest-dummy OMARCHY_MEMORY_BRAKE_MIN_MB=0 OMARCHY_MEMORY_BRAKE_GAP=0
paused=0
for pid in "$dummy_pid" "$dummy2_pid"; do
  [[ $(proc_state "$pid") == "T" ]] && ((++paused))
done
((paused == 1)) || fail "swap 80% with RAM 88% pauses exactly one group, paused $paused"
[[ $(wc -l <"$state/frozen.tsv") == 1 ]] || fail "the brake records one pause" "$(cat "$state/frozen.tsv")"
IFS=$'\t' read -r _ source _ _ _ pids starts <"$state/frozen.tsv"
[[ $source == brake ]] || fail "the brake records itself as the source" "$(cat "$state/frozen.tsv")"
[[ $starts == "$(start_time "$pids")" ]] || fail "the brake records the start time of what it paused"
grep -Fq 'Memory brake: paused sleep' "$NOTIFY_LOG" || fail "the brake says what it paused" "$(cat "$NOTIFY_LOG")"
pass "memory brake pauses one group before oomd's lines"

# Resumed by hand (a plain SIGCONT), the pause no longer holds the brake back.
kill -CONT "$pids"
watch OMARCHY_MEMORY_ONLY=omarchy-memtest-dummy OMARCHY_MEMORY_BRAKE_MIN_MB=0 OMARCHY_MEMORY_BRAKE_GAP=0
grep -Fq 'Memory brake: paused sleep' "$NOTIFY_LOG" || fail "a pause resumed by hand stops holding the brake back"
[[ $(wc -l <"$state/frozen.tsv") == 1 ]] || fail "a resumed pause is dropped from frozen.tsv" "$(cat "$state/frozen.tsv")"
run "$ROOT/bin/omarchy-memory-resume" >/dev/null
for pid in "$dummy_pid" "$dummy2_pid"; do
  [[ $(proc_state "$pid") != "T" ]] || fail "resume continues everything the brake paused"
done
pass "memory brake holds only while its pause does"

# Turning the watchdog off resumes what it paused.
kill -STOP "$dummy_pid"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "2026-01-01 00:00:00" brake "test#$dummy_pid" 1 sleep "$dummy_pid" \
  "$(start_time "$dummy_pid")" >"$state/frozen.tsv"
mkdir -p "$(dirname "$flag")"
touch "$flag"
run "$ROOT/bin/omarchy-toggle-memory-watch" off
sleep 0.2
[[ $(proc_state "$dummy_pid") != "T" ]] || fail "turning the watchdog off resumes what it paused"
pass "memory watchdog toggle off resumes paused groups"

# The brake hands the emergency to the responder, once. The responder's own
# pauses in frozen.tsv never count as the brake's, so pausing something itself
# does not wake a second responder.
rm -f "$state/last-spawn"
: >"$SYSTEMD_RUN_LOG"
: >"$state/frozen.tsv"
kill -STOP "$dummy2_pid"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "2026-01-01 00:00:00" responder "test#$dummy2_pid" 1 sleep "$dummy2_pid" \
  "$(start_time "$dummy2_pid")" >"$state/frozen.tsv"
printf 'MemTotal: 1000000 kB\nMemAvailable: 120000 kB\nSwapTotal: 1000000 kB\nSwapFree: 200000 kB\n' >"$fake/meminfo"
# Another responder pause lands after the brake's, mid-run.
responder_line=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "2026-01-01 00:00:01" responder "test#$dummy2_pid" 1 sleep \
  "$dummy2_pid" "$(start_time "$dummy2_pid")")
(
  sleep 1.5
  printf '%s\n' "$responder_line" >>"$state/frozen.tsv"
) &
watch OMARCHY_MEMORY_ONLY=omarchy-memtest-dummy OMARCHY_MEMORY_BRAKE_MIN_MB=0 OMARCHY_MEMORY_BRAKE_GAP=0
[[ $(proc_state "$dummy_pid") == "T" ]] || fail "a responder's pause does not hold the brake back"
[[ $(grep -c $'\tresponder\t' "$state/frozen.tsv") == 2 ]] || fail "the responder's pauses are kept" "$(cat "$state/frozen.tsv")"
grep -Fq 'omarchy-agent-memory the memory brake paused a process group' "$SYSTEMD_RUN_LOG" ||
  fail "a pause hands the emergency to the responder" "$(cat "$SYSTEMD_RUN_LOG" 2>/dev/null)"
grep -Fq -- '--slice=session.slice' "$SYSTEMD_RUN_LOG" ||
  fail "the responder runs where systemd-oomd cannot kill it"
[[ $(grep -c 'omarchy-agent-memory' "$SYSTEMD_RUN_LOG") == 1 ]] ||
  fail "a pause starts one responder, and the responder's own pauses start none" "$(cat "$SYSTEMD_RUN_LOG")"
run "$ROOT/bin/omarchy-memory-resume" >/dev/null
pass "memory brake hands the emergency to the responder once"

# The cooldown covers a responder the brake would start, too: one started for
# nearly full memory is not followed by another when the brake then pauses.
rm -f "$state/last-spawn"
: >"$SYSTEMD_RUN_LOG"
: >"$state/frozen.tsv"
printf 'MemTotal: 1000000 kB\nMemAvailable: 20000 kB\nSwapTotal: 1000000 kB\nSwapFree: 800000 kB\n' >"$fake/meminfo"
printf 'some avg10=50.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=45.00 avg60=0.00 avg300=0.00 total=0\n' >"$fake/pressure"
(
  sleep 1.2
  setsid bash -c 'exec -a omarchy-memtest-late sleep 300' &
  echo $! >"$TMPDIR/late-pid"
) &
watch OMARCHY_MEMORY_ONLY=omarchy-memtest-late OMARCHY_MEMORY_BRAKE_MIN_MB=0 OMARCHY_MEMORY_BRAKE_GAP=0
late_pid=$(<"$TMPDIR/late-pid")
dummy_pids+=("$late_pid")
[[ $(proc_state "$late_pid") == "T" ]] || fail "the brake pauses what appeared once memory was already short"
grep -Fq 'omarchy-agent-memory memory is nearly full' "$SYSTEMD_RUN_LOG" ||
  fail "RAM 98% with a 45% stall starts the responder" "$(cat "$SYSTEMD_RUN_LOG")"
[[ $(grep -c 'omarchy-agent-memory' "$SYSTEMD_RUN_LOG") == 1 ]] ||
  fail "a pause within the cooldown starts no second responder" "$(cat "$SYSTEMD_RUN_LOG")"
run "$ROOT/bin/omarchy-memory-resume" >/dev/null
pass "memory responder starts at most once per cooldown"

# The cooldown outlasts a restart of the watcher (Restart=always).
[[ -s $state/last-spawn ]] || fail "the watcher keeps when it last started the responder"
: >"$SYSTEMD_RUN_LOG"
watch
[[ ! -s $SYSTEMD_RUN_LOG ]] || fail "a restarted watcher keeps the responder's cooldown" "$(cat "$SYSTEMD_RUN_LOG")"
pass "memory responder cooldown survives a watcher restart"

# A stand-down holds the brake and the responder until RAM recovers; swap
# staying high does not keep it in place.
rm -f "$state/last-spawn"
: >"$SYSTEMD_RUN_LOG"
: >"$state/frozen.tsv"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' >"$fake/pressure"
run "$ROOT/bin/omarchy-memory-reply" standdown
[[ -e $state/standdown ]] || fail "a stand-down is kept for the watcher"
printf 'MemTotal: 1000000 kB\nMemAvailable: 50000 kB\nSwapTotal: 1000000 kB\nSwapFree: 100000 kB\n' >"$fake/meminfo"
watch OMARCHY_MEMORY_ONLY=omarchy-memtest-dummy OMARCHY_MEMORY_BRAKE_MIN_MB=0 OMARCHY_MEMORY_BRAKE_GAP=0
for pid in "$dummy_pid" "$dummy2_pid"; do
  [[ $(proc_state "$pid") != "T" ]] || fail "the brake pauses nothing after a stand-down"
done
[[ ! -s $SYSTEMD_RUN_LOG ]] || fail "no responder starts after a stand-down" "$(cat "$SYSTEMD_RUN_LOG")"
[[ -e $state/standdown ]] || fail "a stand-down lasts while memory is still short"
printf 'MemTotal: 1000000 kB\nMemAvailable: 500000 kB\nSwapTotal: 1000000 kB\nSwapFree: 300000 kB\n' >"$fake/meminfo"
watch
[[ ! -e $state/standdown ]] || fail "a stand-down ends once RAM recovers, even with swap still 70% used"
pass "memory watchdog honours a stand-down until memory recovers"

# zram can hold RAM high for hours, so a stand-down also runs out.
printf 'MemTotal: 1000000 kB\nMemAvailable: 50000 kB\nSwapTotal: 1000000 kB\nSwapFree: 100000 kB\n' >"$fake/meminfo"
touch -d '-31 minutes' "$state/standdown"
watch
[[ ! -e $state/standdown ]] || fail "a stand-down lifts after 30 minutes even with memory still short"
grep -Fq 'Memory watchdog is back on' "$NOTIFY_LOG" || fail "a toast says the stand-down lifted" "$(cat "$NOTIFY_LOG")"
pass "memory watchdog stand-down expires"

# The brake leaves AI agent sessions running, so the responder can message
# them, and still pauses what they started.
setsid bash -c 'exec -a claude bash -c "sleep 3031 & wait"' &
agent_pid=$!
dummy_pids+=("$agent_pid")
sleep 0.3
agent_child=$(pgrep -P "$agent_pid" -x sleep)
dummy_pids+=("$agent_child")
picked=$(OMARCHY_MEMORY_ONLY='sleep 3031$|^bash claude' run "$ROOT/bin/omarchy-memory-top" --pick 0) ||
  fail "the brake picks what an agent started"
IFS=$'\t' read -r _ _ _ pids _ <<<"$picked"
[[ $pids == "$agent_child" ]] || fail "the brake pauses the agent's child and never the agent, got: $picked"
pass "memory brake protects agent sessions, not what they start"

# Every signal the responder sends goes through omarchy-memory-kill.
kill_dummy() {
  setsid bash -c 'exec -a omarchy-memtest-kill sleep 300' &
  kill_pid=$!
  dummy_pids+=("$kill_pid")
  sleep 0.2
}
kill_dummy
: >"$state/frozen.tsv"
run "$ROOT/bin/omarchy-memory-kill" "$kill_pid" STOP >/dev/null || fail "memory kill pauses a plain process"
[[ $(proc_state "$kill_pid") == "T" ]] || fail "memory kill STOP stops the process"
IFS=$'\t' read -r _ source _ _ _ pids starts <"$state/frozen.tsv"
[[ $source == user && $pids == "$kill_pid" && $starts == "$(start_time "$kill_pid")" ]] ||
  fail "memory kill records a pause for resume" "$(cat "$state/frozen.tsv")"
run "$ROOT/bin/omarchy-memory-kill" "$kill_pid" TERM >/dev/null || fail "memory kill terminates a plain process"
sleep 0.3
[[ ! -e /proc/$kill_pid ]] || [[ $(proc_state "$kill_pid") == Z ]] ||
  fail "memory kill continues a stopped process before SIGTERM, so it actually exits"
grep -Fq "sent SIGTERM to sleep ($kill_pid" "$state/watch.log" || fail "memory kill logs what it did"
pass "memory kill pauses and terminates, and records it"

kill_dummy
if run "$ROOT/bin/omarchy-memory-kill" 1 TERM 2>/dev/null; then
  fail "memory kill refuses another user's process"
fi
if run "$ROOT/bin/omarchy-memory-kill" "$agent_pid" TERM 2>/dev/null; then
  fail "memory kill refuses an AI agent session"
fi
if OMARCHY_MEMORY_PROTECT='^sleep$' run "$ROOT/bin/omarchy-memory-kill" "$kill_pid" TERM 2>/dev/null; then
  fail "memory kill refuses a protected process"
fi
if run "$ROOT/bin/omarchy-memory-kill" "$kill_pid" HUP 2>/dev/null; then
  fail "memory kill sends only TERM, KILL, STOP and CONT"
fi
[[ $(proc_state "$kill_pid") == S && $(proc_state "$agent_pid") == S ]] || fail "a refused signal is never sent"
grep -Fq "refused SIGTERM to bash ($agent_pid)" "$state/watch.log" || fail "memory kill logs what it refused"
pass "memory kill refuses what the responder must never touch"

# The responder and the relay start in omarchy-agent's own permission modes,
# with their tools cut down and no MCP servers. Fakes only: never a real agent.
cat >"$TMPDIR/bin/claude" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$AGENT_LOG"
SH
cp "$TMPDIR/bin/claude" "$TMPDIR/bin/codex"
printf '#!/bin/bash\necho "$FAKE_AGENT"\n' >"$TMPDIR/bin/omarchy-default-agent"
chmod +x "$TMPDIR/bin/claude" "$TMPDIR/bin/codex" "$TMPDIR/bin/omarchy-default-agent"
agent_log="$TMPDIR/agent-log"
run env AGENT_LOG="$agent_log" FAKE_AGENT=claude "$ROOT/bin/omarchy-agent-memory" test
run env AGENT_LOG="$agent_log" FAKE_AGENT=codex "$ROOT/bin/omarchy-agent-memory" test
run env AGENT_LOG="$agent_log" "$ROOT/bin/omarchy-memory-message" some-session hello >/dev/null
claude_line=$(grep -F -- '-p --permission-mode auto --restricted --tools Bash,Read,Write,ToolSearch,SendMessage,ListAgents --settings' "$agent_log")
[[ $claude_line == *--strict-mcp-config* ]] || fail "the Claude responder runs in restricted auto mode with only its tools" "$(cat "$agent_log")"
for rule in 'Bash(kill:*)' 'Bash(pkill:*)' 'Bash(killall:*)' 'Bash(rm:*)' 'Bash(systemctl:*)'; do
  jq -e --arg rule "$rule" '.permissions.deny | index($rule)' <<<"$(sed -E 's/.* --settings (\{.*\}\}) --add-dir.*/\1/' <<<"$claude_line")" >/dev/null ||
    fail "the Claude responder may not run $rule" "$claude_line"
done
grep -F -- "Edit(/$state/**)" <<<"$claude_line" >/dev/null || fail "the Claude responder writes only in the state directory" "$claude_line"
grep -F -- 'exec --sandbox danger-full-access -c approval_policy="on-request" -c approvals_reviewer="auto_review" --ignore-user-config' "$agent_log" >/dev/null ||
  fail "the Codex responder runs outside the sandbox, which hides every other process" "$(cat "$agent_log")"
grep -F -- '--model haiku --permission-mode auto --restricted --tools ToolSearch,SendMessage,ListAgents' "$agent_log" >/dev/null ||
  fail "the message relay runs in auto mode with only the tools to send" "$(cat "$agent_log")"
! grep -Eq 'bypassPermissions|dangerously' "$agent_log" || fail "nothing skips permissions outright" "$(cat "$agent_log")"
pass "memory responder and relay use omarchy-agent's permission modes"

# Replies are a fixed vocabulary, since a toast click writes them.
if run "$ROOT/bin/omarchy-memory-reply" 'kill everything' 2>/dev/null; then
  fail "the reply command rejects anything but approve, standdown and resolved"
fi
run "$ROOT/bin/omarchy-memory-reply" approve
[[ $(<"$state/reply") == "approve" ]] || fail "the reply command records the answer"
pass "memory reply accepts only known answers"

run "$ROOT/bin/omarchy-memory-note" "test note" >/dev/null
grep -Fq $'\t''test note' "$state/agent-notes.log" || fail "agent notes are logged"
pass "memory note logs agent replies"

# Turning the watchdog off also stops a responder that is still running.
: >"$SYSTEMCTL_LOG"
touch "$flag" "$state/standdown"
run "$ROOT/bin/omarchy-toggle-memory-watch" off
grep -Fqx -- "--user stop omarchy-memory-agent.service" "$SYSTEMCTL_LOG" ||
  fail "turning the watchdog off stops a running responder" "$(cat "$SYSTEMCTL_LOG")"
[[ ! -e $state/standdown ]] || fail "turning the watchdog off forgets a stand-down"
pass "memory watchdog toggle off stops the responder"

skill="$ROOT/default/agents/skills/memory-emergency/SKILL.md"
grep -Fx 'name: memory-emergency' "$skill" >/dev/null || fail "the responder's skill is named for the prompt that loads it"
migration=$(grep -rl 'memory-emergency' "$ROOT/migrations" | head -n 1 || true)
[[ -n $migration ]] || fail "existing installs never get the memory-emergency skill linked"
grep -F 'omarchy-memory-watch.service' "$migration" | grep -F 'enable' >/dev/null &&
  fail "the migration turns on an opt-in watchdog"
mkdir -p "$test_home/.hermes/profiles/work"
run bash -c "source '$migration'" >/dev/null
for dir in .agents/skills .claude/skills .codex/skills .pi/agent/skills .gemini/config/skills .hermes/skills \
  .hermes/profiles/work/skills; do
  [[ -L $test_home/$dir/memory-emergency ]] || fail "the migration links the skill where provisioning does: $dir"
done
pass "memory-emergency skill ships to every agent, and the watchdog stays opt-in"
