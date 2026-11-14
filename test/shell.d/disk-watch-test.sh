#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export HOME="$TMPDIR/home"
export OMARCHY_PATH="$ROOT"
export OMARCHY_DISK_CONFIG="$HOME/.config/omarchy/disk-watch.conf"
export OMARCHY_DISK_MIN_BYTES=0
export PATH="$TMPDIR/bin:$ROOT/bin:$PATH"
mkdir -p "$TMPDIR/bin" "$HOME/.config/omarchy" "$HOME/Work" "$HOME/.cache"
export SYSTEMD_RUN_LOG="$TMPDIR/systemd-run-log" NOTIFY_LOG="$TMPDIR/notify-log" ACTIVE="$TMPDIR/active"

cat >"$OMARCHY_DISK_CONFIG" <<EOF
watch = $TMPDIR
worktree_root = ~/Work
cache = ~/.cache/b[0-9]* 2
large = ~/Games/* 30
protect = ~/Work/keepme-wt
EOF

g() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
old=$(date -d '-10 days' '+%F %T')

# A repo with main and four linked worktrees.
repo="$HOME/Work/app"
mkdir -p "$repo"
g -C "$repo" init -q -b main
echo one >"$repo/a"
g -C "$repo" add a
GIT_COMMITTER_DATE="$old" g -C "$repo" commit -qm init --date "$old"
# Build output, ignored like target/ in a Rust repo (info/exclude is shared by its worktrees).
echo "target/" >>"$repo/.git/info/exclude"
echo ".env" >>"$repo/.git/info/exclude"
for name in merged dirty unmerged fresh unstarted secrets busy keepme; do
  wt="$HOME/Work/app-wt/$name"
  [[ $name == "keepme" ]] && wt="$HOME/Work/keepme-wt/integration"
  g -C "$repo" worktree add -q "$wt" -b "$name" main
  [[ $name == "keepme" ]] && { touch -d "$old" "$repo/.git/worktrees/integration/index"; continue; }
  mkdir -p "$HOME/Work/app-wt/$name/target"
  head -c 200000 /dev/urandom >"$HOME/Work/app-wt/$name/target/big.o"
  # Work on the branch, merged into main, except for the one never started.
  if [[ $name != "unstarted" ]]; then
    echo "$name" >"$HOME/Work/app-wt/$name/$name.txt"
    g -C "$HOME/Work/app-wt/$name" add "$name.txt"
    GIT_COMMITTER_DATE="$old" g -C "$HOME/Work/app-wt/$name" commit -qm "$name" --date "$old"
    GIT_COMMITTER_DATE="$old" g -C "$repo" merge -q --no-ff "$name" -m "merge $name"
  fi
done
echo "wip" >"$HOME/Work/app-wt/dirty/notes.txt"
echo two >>"$HOME/Work/app-wt/unmerged/a"
GIT_COMMITTER_DATE="$old" g -C "$HOME/Work/app-wt/unmerged" commit -qam "not on main" --date "$old"
echo "TOKEN=hunter2" >"$HOME/Work/app-wt/secrets/.env"
# Old checkouts, except fresh.
for name in merged dirty unmerged unstarted secrets busy; do
  touch -d "$old" "$repo/.git/worktrees/$name/index"
done
# Someone working in one: a real process with its cwd inside.
(cd "$HOME/Work/app-wt/busy/target" && exec sleep 60) &
busy_pid=$!
trap 'kill "$busy_pid" 2>/dev/null; rm -rf "$TMPDIR"' EXIT
sleep 0.2

mkdir -p "$HOME/.cache/b12-scratch" "$HOME/.cache/b13-live"
head -c 100000 /dev/urandom >"$HOME/.cache/b12-scratch/blob"
head -c 100000 /dev/urandom >"$HOME/.cache/b13-live/blob"
touch -d "$old" "$HOME/.cache/b12-scratch/blob" "$HOME/.cache/b12-scratch"

scan=$(omarchy-disk-top --json)
tier() { jq -r --arg p "$1" '.candidates[] | select(.path == $p) | .tier' <<<"$scan"; }

[[ $(tier "$HOME/Work/app-wt/merged") == "safe" ]] || fail "a merged, clean, idle worktree is safe" "$scan"
[[ $(tier "$HOME/Work/app-wt/dirty") != "safe" ]] || fail "a worktree with an untracked file is not safe" "$scan"
[[ $(tier "$HOME/Work/app-wt/unmerged") != "safe" ]] || fail "a worktree with a commit not on main is not safe" "$scan"
[[ $(tier "$HOME/Work/app-wt/fresh") != "safe" ]] || fail "a worktree checked out just now is not safe" "$scan"
[[ $(tier "$HOME/Work/app-wt/unstarted") != "safe" ]] || fail "a branch with no commits of its own is not safe" "$scan"
[[ $(tier "$HOME/Work/app-wt/secrets") == "ask" ]] || fail "a worktree holding an ignored file that is not build output is the user's call" "$scan"
[[ $(tier "$HOME/Work/app-wt/busy") == "keep" ]] || fail "a worktree a process is working in is kept" "$scan"
[[ $(tier "$HOME/.cache/b12-scratch") == "safe" ]] || fail "an idle cache glob is safe" "$scan"
[[ $(tier "$HOME/.cache/b13-live") == "keep" ]] || fail "a cache touched today is kept" "$scan"
[[ -z $(tier "$repo") ]] || fail "the main repo is never a candidate" "$scan"
[[ -z $(tier "$HOME/Work/keepme-wt/integration") ]] || fail "a protected worktree is never a candidate" "$scan"
pass "omarchy disk top sorts worktrees and caches into safe and not"

out=$(omarchy-disk-reclaim "$HOME/Work/app-wt/dirty" "$HOME/Work/app-wt/unmerged" 2>&1) && fail "reclaim refuses unsafe items with a failing status" "$out"
[[ -d $HOME/Work/app-wt/dirty && -f $HOME/Work/app-wt/dirty/notes.txt && -d $HOME/Work/app-wt/unmerged ]] ||
  fail "refused worktrees stay" "$out"
[[ $out == *"refused"* ]] || fail "reclaim says what it refused" "$out"
out=$(omarchy-disk-reclaim "$HOME/Work/app-wt/secrets" "$HOME/Work/app-wt/busy" 2>&1) && fail "reclaim refuses ask and busy worktrees" "$out"
[[ -f $HOME/Work/app-wt/secrets/.env && -d $HOME/Work/app-wt/busy ]] || fail "the .env and the busy worktree stay" "$out"
pass "omarchy disk reclaim refuses dirty, unmerged, busy and secret-holding worktrees"

out=$(omarchy-disk-reclaim "worktree:$HOME/Work/app-wt/merged" "$HOME/.cache/b12-scratch" 2>&1) || fail "reclaim frees safe items" "$out"
[[ ! -e $HOME/Work/app-wt/merged && ! -e $HOME/.cache/b12-scratch ]] || fail "safe items are gone" "$out"
g -C "$repo" rev-parse --verify --quiet refs/heads/merged >/dev/null || fail "the merged worktree's branch stays" "$out"
[[ -f $repo/a && -d $HOME/.cache/b13-live ]] || fail "the repo and the live cache are untouched" "$out"
grep -q "freed" "$HOME/.local/state/omarchy/disk-watch/reclaim.log" || fail "reclaim logs what it freed" "$(cat "$HOME/.local/state/omarchy/disk-watch/reclaim.log")"
pass "omarchy disk reclaim frees a merged worktree and an idle cache, branch kept"

# An idle game is the user's call: refused without --approved.
mkdir -p "$HOME/Games/old"
head -c 100000 /dev/urandom >"$HOME/Games/old/data.pak"
touch -d '-60 days' "$HOME/Games/old/data.pak" "$HOME/Games/old"
export OMARCHY_DISK_LARGE_BYTES=0
out=$(omarchy-disk-reclaim "$HOME/Games/old" 2>&1) && fail "an ask item is refused without approval" "$out"
[[ -f $HOME/Games/old/data.pak ]] || fail "the game stays without approval" "$out"
pass "omarchy disk reclaim leaves ask items to the user"

# The watcher, fed numbers. Never a real unit, toast or reclaim.
cat >"$TMPDIR/bin/systemd-run" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$SYSTEMD_RUN_LOG"
[[ $* == *omarchy-disk-agent* ]] && touch "$ACTIVE"
exit 0
SH
cat >"$TMPDIR/bin/systemctl" <<'SH'
#!/bin/bash
[[ $* == *is-active*omarchy-disk-agent* && -e $ACTIVE ]] && exit 0
exit 3
SH
cat >"$TMPDIR/bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$NOTIFY_LOG"
SH
chmod +x "$TMPDIR/bin/"*
export OMARCHY_DISK_DF="$TMPDIR/df" OMARCHY_DISK_ONCE=1
G=$((1024 * 1024 * 1024))
step() { echo "$TMPDIR $1 $(($2 * G))" >"$OMARCHY_DISK_DF"; omarchy-disk-watch 2>/dev/null; sleep 0.2; }
count() { grep -c -- "$1" "$2" 2>/dev/null || true; }

step 80 200
[[ ! -s $NOTIFY_LOG && ! -s $SYSTEMD_RUN_LOG ]] || fail "80% full does nothing" "$(cat "$NOTIFY_LOG" "$SYSTEMD_RUN_LOG" 2>/dev/null)"
step 86 140
(($(count "is 86% full" "$NOTIFY_LOG") == 1)) || fail "86% full warns" "$(cat "$NOTIFY_LOG")"
step 87 130
(($(count "% full" "$NOTIFY_LOG") == 1)) || fail "one more point does not warn again" "$(cat "$NOTIFY_LOG")"
step 89 110
(($(count "is 89% full" "$NOTIFY_LOG") == 1)) || fail "three points more warns again" "$(cat "$NOTIFY_LOG")"
pass "the watcher warns at 85% and again every 3 points"

step 93 70
(($(count "omarchy-agent-disk $TMPDIR" "$SYSTEMD_RUN_LOG") == 1)) || fail "93% full starts the responder" "$(cat "$SYSTEMD_RUN_LOG")"
step 93 70
(($(count "omarchy-agent-disk" "$SYSTEMD_RUN_LOG") == 1)) || fail "a running responder is not started twice" "$(cat "$SYSTEMD_RUN_LOG")"
rm -f "$ACTIVE"
step 93 70
step 94 60
(($(count "omarchy-agent-disk" "$SYSTEMD_RUN_LOG") == 1)) || fail "a drive the responder left full does not restart it" "$(cat "$SYSTEMD_RUN_LOG")"
step 95 50
(($(count "omarchy-agent-disk" "$SYSTEMD_RUN_LOG") == 2)) || fail "two points past where it left off starts it again" "$(cat "$SYSTEMD_RUN_LOG")"
pass "the watcher hands a nearly full drive to the responder, and re-arms only as it fills"

step 98 20
(($(count "omarchy-disk-brake" "$SYSTEMD_RUN_LOG") == 1)) || fail "98% full brakes" "$(cat "$SYSTEMD_RUN_LOG")"
[[ $(grep omarchy-disk-brake "$SYSTEMD_RUN_LOG") == *"omarchy-disk-reclaim --safe --mount"* ]] || fail "the brake frees the safe tier" "$(cat "$SYSTEMD_RUN_LOG")"
step 98 20
(($(count "omarchy-disk-brake" "$SYSTEMD_RUN_LOG") == 1)) || fail "the brake waits its gap" "$(cat "$SYSTEMD_RUN_LOG")"
pass "the watcher frees the safe tier itself at 97%"
