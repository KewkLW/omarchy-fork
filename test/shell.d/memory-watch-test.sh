#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

TMPDIR=$(mktemp -d)
dummy_pid=
cleanup() {
  [[ -n $dummy_pid ]] && kill -CONT "$dummy_pid" 2>/dev/null && kill "$dummy_pid" 2>/dev/null
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

mkdir -p "$TMPDIR/bin"
SYSTEMCTL_LOG="$TMPDIR/systemctl-log"

cat >"$TMPDIR/bin/systemctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
SH

cat >"$TMPDIR/bin/omarchy-notification-send" <<'SH'
#!/bin/bash
exit 0
SH

chmod +x "$TMPDIR/bin/systemctl" "$TMPDIR/bin/omarchy-notification-send"

test_home="$TMPDIR/home"
flag="$test_home/.local/state/omarchy/toggles/memory-watch-on"
state="$test_home/.local/state/omarchy/memory-watch"

run() {
  PATH="$TMPDIR/bin:$ROOT/bin:$PATH" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" HOME="$test_home" "$@"
}

# Toggle: opt-in, so the first toggle turns it on.
run "$ROOT/bin/omarchy-toggle-memory-watch"
[[ -f $flag ]] || fail "the first memory watchdog toggle turns it on"
grep -Fqx -- "--user enable --now omarchy-memory-watch.service" "$SYSTEMCTL_LOG" ||
  fail "enabling the memory watchdog starts it now and at every login"
pass "memory watchdog toggle enables the watcher"

: >"$SYSTEMCTL_LOG"
run "$ROOT/bin/omarchy-toggle-memory-watch"
[[ ! -f $flag ]] || fail "the second memory watchdog toggle turns it off"
grep -Fqx -- "--user disable --now omarchy-memory-watch.service" "$SYSTEMCTL_LOG" ||
  fail "disabling the memory watchdog stops it now and at every login"
pass "memory watchdog toggle disables the watcher"

service="$ROOT/default/systemd/user/omarchy-memory-watch.service"
grep -Fx 'ConditionPathExists=%h/.local/state/omarchy/toggles/memory-watch-on' "$service" >/dev/null ||
  fail "the memory watchdog stays opt-in even when its unit is enabled"
pass "memory watchdog unit is opt-in"

# The brake picks unprotected groups only, and never stopped ones.
# Its own process group, like a job started from a terminal or an agent's shell.
setsid bash -c 'exec -a omarchy-memtest-dummy sleep 300' &
dummy_pid=$!
sleep 0.2

picked=$(OMARCHY_MEMORY_ONLY=omarchy-memtest-dummy run "$ROOT/bin/omarchy-memory-top" --pick 0) ||
  fail "the brake can pick an unprotected process group"
[[ $picked == *$'\t'"$dummy_pid" ]] || fail "the brake picks the dummy's own pids, got: $picked"
pass "memory brake picks an unprotected group"

if OMARCHY_MEMORY_ONLY=omarchy-memtest-dummy OMARCHY_MEMORY_PROTECT='^sleep$' run "$ROOT/bin/omarchy-memory-top" --pick 0 >/dev/null; then
  fail "the brake never picks a protected group"
fi
pass "memory brake skips protected groups"

# Resume sends SIGCONT to exactly what the brake recorded.
kill -STOP "$dummy_pid"
mkdir -p "$state"
printf '%s\t%s\t%s\t%s\t%s\n' "2026-01-01 00:00:00" "test#$dummy_pid" 1 sleep "$dummy_pid" >"$state/frozen.tsv"

if OMARCHY_MEMORY_ONLY=omarchy-memtest-dummy run "$ROOT/bin/omarchy-memory-top" --pick 0 >/dev/null; then
  fail "the brake doesn't pick a group it already paused"
fi
pass "memory brake skips stopped groups"

run "$ROOT/bin/omarchy-memory-resume" sleep >/dev/null
sleep 0.2
[[ $(awk '{ print $3 }' "/proc/$dummy_pid/stat") != "T" ]] || fail "resume continues the paused group"
[[ ! -s $state/frozen.tsv ]] || fail "resume clears what it resumed from frozen.tsv"
pass "memory resume continues paused groups"

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
