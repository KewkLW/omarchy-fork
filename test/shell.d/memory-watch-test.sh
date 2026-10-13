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

# Whatever holds frozen.lock: waits until it has it.
wait_locked() {
  local i
  for ((i = 0; i < 50; i++)); do
    flock -n "$state/frozen.lock" true || return 0
    sleep 0.1
  done
  fail "the test's lock holder takes frozen.lock"
}

# A resume that holds frozen.lock past the brake's wait rewrites frozen.tsv
# from the copy it read, dropping any line appended meanwhile. The brake
# pauses nothing it cannot record under the lock.
setsid bash -c 'exec -a omarchy-memtest-locked sleep 3040' &
locked_pid=$!
dummy_pids+=("$locked_pid")
: >"$state/frozen.tsv"
: >"$state/watch.log"
(
  flock 9
  cp "$state/frozen.tsv" "$TMPDIR/frozen.kept"
  sleep 8.5
  mv "$TMPDIR/frozen.kept" "$state/frozen.tsv"
) 9>"$state/frozen.lock" &
holder=$!
wait_locked
run env OMARCHY_MEMORY_MEMINFO="$fake/meminfo" OMARCHY_MEMORY_PRESSURE="$fake/pressure" \
  OMARCHY_MEMORY_APP_PRESSURE="$fake/app-pressure" OMARCHY_MEMORY_INTERVAL=0.2 \
  OMARCHY_MEMORY_ONLY=omarchy-memtest-locked OMARCHY_MEMORY_BRAKE_MIN_MB=0 \
  timeout 7.5 "$ROOT/bin/omarchy-memory-watch" 2>/dev/null || true
wait "$holder"
if [[ $(proc_state "$locked_pid") == "T" ]]; then
  grep -Fq $'\t'"$locked_pid"$'\t' "$state/frozen.tsv" ||
    fail "the brake never leaves a group paused with no record to resume it" "$(cat "$state/frozen.tsv")"
fi
[[ $(proc_state "$locked_pid") != "T" ]] && grep -Fq 'brake: frozen.tsv stayed locked; left sleep running' "$state/watch.log" ||
  fail "the brake pauses nothing while it cannot take frozen.lock, and says so" "$(cat "$state/watch.log")"
pass "memory brake pauses only what it can record"

# Turning the watchdog off stops it with a TERM to everything in its unit, then
# resumes what frozen.tsv lists. A TERM while the brake is under way must not
# leave a group stopped with no line there.
: >"$state/frozen.tsv"
: >"$state/watch.log"
(
  flock 9
  exec -a omarchy-memtest-lockhold sleep 3041
) 9>"$state/frozen.lock" &
holder=$!
dummy_pids+=("$holder")
wait_locked
run env OMARCHY_MEMORY_MEMINFO="$fake/meminfo" OMARCHY_MEMORY_PRESSURE="$fake/pressure" \
  OMARCHY_MEMORY_APP_PRESSURE="$fake/app-pressure" OMARCHY_MEMORY_INTERVAL=0.2 \
  OMARCHY_MEMORY_ONLY=omarchy-memtest-locked OMARCHY_MEMORY_BRAKE_MIN_MB=0 \
  timeout 10 "$ROOT/bin/omarchy-memory-watch" 2>/dev/null &
watch_job=$!
# timeout leads its own process group, as a unit's cgroup holds the watcher.
group= waiter=
for _ in {1..50}; do
  group=$(pgrep -P "$watch_job" -x timeout || true)
  [[ -n $group ]] && waiter=$(pgrep -g "$group" -x flock || true)
  [[ -n $waiter ]] && break
  sleep 0.1
done
[[ -n $waiter ]] || fail "the brake waits for frozen.lock while something else holds it"
kill -TERM -- -"$group"
sleep 0.3
kill "$holder"
wait "$watch_job" || true
! pgrep -g "$group" >/dev/null || fail "a TERM during the brake still stops the watcher"
if [[ $(proc_state "$locked_pid") == "T" ]]; then
  grep -Fq $'\t'"$locked_pid"$'\t' "$state/frozen.tsv" ||
    fail "a TERM during the brake never leaves a group paused with no record" "$(cat "$state/frozen.tsv")"
fi
run "$ROOT/bin/omarchy-memory-resume" >/dev/null
[[ $(proc_state "$locked_pid") != "T" ]] || fail "resume continues a pause the brake made as it was stopped"
pass "memory brake leaves nothing paused unrecorded when stopped"

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

# A game's own binary often has a bland name (under gamescope, or a Proton
# helper), so the brake protects everything under a game: a child in the
# game's group, and one in a group of its own.
setsid bash -c 'exec -a /tmp/memtest/steamapps/common/game.exe bash -c "sleep 3032 & setsid -w sleep 3033 & wait"' &
game_pid=$!
dummy_pids+=("$game_pid")
sleep 0.3
game_children=$(pgrep -P "$game_pid" -x sleep | sort -n | paste -sd' ')
dummy_pids+=($game_children)
[[ $game_children == *' '* ]] || fail "the game's children started" "$game_children"
if picked=$(OMARCHY_MEMORY_ONLY='sleep 303[23]$' run "$ROOT/bin/omarchy-memory-top" --pick 0); then
  fail "the brake never pauses what runs under a game" "$picked"
fi
pass "memory brake protects everything under a game"
