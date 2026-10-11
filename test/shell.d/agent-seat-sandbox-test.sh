#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command bwrap
if ! bwrap_works; then
  skip "bubblewrap cannot create a sandbox here; skipping the agent seat sandbox"
  exit 0
fi
require_command jq
require_command python3

# The seat commands find their sandbox supervisor under $OMARCHY_PATH.
export OMARCHY_PATH="$ROOT"

real_home=$HOME
real_runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
test_dir=$(mktemp -d)
home="$test_dir/home"
runtime="$test_dir/runtime"
seat="$runtime/omarchy/agent-seat"
mkdir -p "$test_dir/bin" "$test_dir/out" "$test_dir/scratch" "$runtime" \
  "$home/.ssh" "$home/.gnupg" "$home/.config/app" "$home/.local/share/keyrings"
echo "canary" >"$home/canary"
echo "scratch" >"$test_dir/scratch/file"
echo "secret" >"$test_dir/secret"

cleanup() {
  local record pid

  # Only the sandboxes this test started: their records live in its own runtime.
  for record in "$seat"/sandboxes/sandbox.*; do
    [[ -e $record ]] || continue
    read -r pid _ <"$record" || continue
    [[ $pid =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null
  done
  [[ -n ${launcher_pid:-} ]] && kill "$launcher_pid" 2>/dev/null
  [[ -n ${broker_pid:-} ]] && kill "$broker_pid" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$test_dir"
}
trap cleanup EXIT

# The broker asks Hyprland where agent windows are; there is no Hyprland here.
printf '#!/bin/bash\necho "[]"\n' >"$test_dir/bin/hyprctl"
chmod +x "$test_dir/bin/hyprctl"

# env execs the command, so a background launch's $! is the command itself.
on_seat=(env HOME="$home" XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY=no-compositor PATH="$test_dir/bin:$ROOT/bin:$PATH")

# A share that slipped through must not start a broker this test can't end,
# so these launches find a broker that refuses to serve.
mkdir -p "$test_dir/no-broker"
printf '#!/bin/bash\nexit 1\n' >"$test_dir/no-broker/omarchy-agent-seat-broker"
chmod +x "$test_dir/no-broker/omarchy-agent-seat-broker"

refused() {
  local output

  output=$("${on_seat[@]}" PATH="$test_dir/no-broker:$ROOT/bin:$PATH" omarchy-agent-seat-run "$@" /usr/bin/true 2>&1) && return 1
  [[ $output == "Refusing "* ]]
}

for path in / "$home" /tmp "$runtime" "$real_runtime" "$home/.ssh" "$home/.gnupg" "$home/.config/app" "$home/.local/share/keyrings" "$home/.local" /proc/self /dev; do
  refused --share "$path" || fail "sharing $path is refused"
  refused --share-ro "$path" || fail "sharing $path read-only is refused"
done
[[ ! -e $seat ]] || fail "a refused share starts nothing"
pass "shares of the root, home, /tmp, runtime directories, /proc, /dev and private config are refused"

printf '#!/bin/bash\n' >"$home/.config/app/tool"
chmod +x "$home/.config/app/tool"
output=$("${on_seat[@]}" PATH="$test_dir/no-broker:$ROOT/bin:$PATH" omarchy-agent-seat-run "$home/.config/app/tool" 2>&1) && fail "a program inside ~/.config is refused"
[[ $output == "Refusing "* ]] || fail "a program inside ~/.config is refused" "$output"
pass "a program inside ~/.config is refused"

"${on_seat[@]}" omarchy-agent-seat-broker serve 2>"$test_dir/broker.log" &
broker_pid=$!
for _ in {1..50}; do [[ -S $seat/wayland-0 ]] && break; sleep 0.1; done
[[ -S $seat/wayland-0 ]] || fail "the broker starts" "$(cat "$test_dir/broker.log")"

# Runs a headless command on the seat and waits for its sandbox to end.
run_headless() {
  "${on_seat[@]}" omarchy-agent-seat-run --no-wait "$@" || return 1
  for _ in {1..100}; do
    compgen -G "$seat/sandboxes/sandbox.*" >/dev/null || return 0
    sleep 0.05
  done
  return 1
}

# Lives in the test directory under /tmp, beside the fake home and runtime, so
# binding its directory would hand all of that to the sandbox.
cat >"$test_dir/probe" <<'EOF'
#!/bin/bash
out=$1 scratch=$2 test_dir=$3 real_home=$4 real_runtime=$5 signature=$6
{
  [[ -e $HOME/canary || -e $test_dir/home/canary ]] && echo "home visible"
  [[ -e $real_home ]] && echo "user home visible"
  [[ -e /run/user ]] && echo "/run/user visible"
  [[ -e $real_runtime ]] && echo "real runtime visible"
  [[ -e /tmp/.X11-unix ]] && echo "X11 visible"
  [[ -e $XDG_RUNTIME_DIR/hypr || -e $real_runtime/hypr ]] && echo "hypr visible"
  [[ -e $XDG_RUNTIME_DIR/bus || -e $real_runtime/bus ]] && echo "D-Bus visible"
  [[ -e $XDG_RUNTIME_DIR/keyring || -e $real_runtime/keyring/control ]] && echo "keyring visible"
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && echo "Hyprland signature set"
  if [[ -n $signature ]] && HYPRLAND_INSTANCE_SIGNATURE=$signature XDG_RUNTIME_DIR=$real_runtime hyprctl -j monitors >/dev/null 2>&1; then
    echo "hyprctl reaches Hyprland"
  fi
  echo "runtime: $(ls -A "$XDG_RUNTIME_DIR" | tr '\n' ' ')"
  [[ -e $(dirname "$0")/secret ]] && echo "probe directory visible"
  echo "scratch: $(cat "$scratch/file")"
  touch "$scratch/new" 2>/dev/null && echo "scratch writable"
  echo "done"
} >"$out/result" 2>&1
EOF
chmod +x "$test_dir/probe"

run_headless --share "$test_dir/out" --share-ro "$test_dir/scratch" "$test_dir/probe" \
  "$test_dir/out" "$test_dir/scratch" "$test_dir" "$real_home" "$real_runtime" "${HYPRLAND_INSTANCE_SIGNATURE:-}" ||
  fail "a headless probe runs in the sandbox" "$(cat "$seat/apps.log" 2>/dev/null)"
result=$(cat "$test_dir/out/result" 2>/dev/null)
[[ $result == *"done"* ]] || fail "the probe reports back through a shared directory" "$result $(cat "$seat/apps.log" 2>/dev/null)"
pass "a shared directory is writable from the sandbox"

for leak in "home visible" "user home visible" "/run/user visible" "real runtime visible" "X11 visible" \
  "hypr visible" "D-Bus visible" "keyring visible" "Hyprland signature set" "hyprctl reaches Hyprland"; do
  [[ $result != *"$leak"* ]] || fail "the sandbox hides the user's session: $leak" "$result"
done
grep -qx "runtime: agent-bus wayland-0 " <<<"$result" || fail "the sandbox's runtime directory holds only the broker socket and its private bus" "$result"
pass "the sandbox sees no home, X11, Hyprland, D-Bus or keyring, and only the broker socket and its private bus"

[[ $result != *"probe directory visible"* ]] || fail "a program outside /usr gets only its own file" "$result"
pass "a program outside /usr gets only its own file, not its directory"

grep -qx "scratch: scratch" <<<"$result" || fail "a read-only share is readable" "$result"
[[ $result != *"scratch writable"* && ! -e $test_dir/scratch/new ]] || fail "a read-only share is not writable" "$result"
pass "a read-only share of a scratch directory is readable and not writable"

# An app bundle keeps its libraries and resources beside the executable.
mkdir -p "$test_dir/opt/app/lib" "$test_dir/opt/tool"
printf '#!/bin/bash\nls -A "$(dirname "$0")" >"%s/bundle"\n' "$test_dir/out" >"$test_dir/opt/app/app"
cp "$test_dir/opt/app/app" "$test_dir/opt/tool/tool"
sed -i 's|/bundle"|/plain"|' "$test_dir/opt/tool/tool"
touch "$test_dir/opt/tool/data"
chmod +x "$test_dir/opt/app/app" "$test_dir/opt/tool/tool"
run_headless --share "$test_dir/out" "$test_dir/opt/app/app" || fail "a bundled app runs"
run_headless --share "$test_dir/out" "$test_dir/opt/tool/tool" || fail "a lone program runs"
[[ $(tr '\n' ' ' <"$test_dir/out/bundle") == "app lib " ]] || fail "an app bundle gets its directory" "$(cat "$test_dir/out/bundle")"
[[ $(tr '\n' ' ' <"$test_dir/out/plain") == "tool " ]] || fail "a directory that is no bundle stays hidden" "$(cat "$test_dir/out/plain")"
pass "an app bundle gets its directory, other programs only their file"

# A launch that waits for its window keeps other launches from diffing the
# window list until it has one, without holding up stop.
"${on_seat[@]}" omarchy-agent-seat-run /usr/bin/sleep 30 >/dev/null 2>&1 &
launcher_pid=$!
for _ in {1..50}; do
  compgen -G "$seat/sandboxes/sandbox.*" >/dev/null && break
  sleep 0.05
done
sleep 0.2
flock -n "$seat/launch.lock" true && fail "a waiting launch holds the launch lock"
flock -n "$seat/sandboxes.lock" true || fail "a waiting launch does not hold up stop"
"${on_seat[@]}" omarchy-agent-seat-run --no-wait /usr/bin/true &
second_pid=$!
sleep 0.5
kill -0 "$second_pid" 2>/dev/null || fail "a second launch waits for the first to find its window"
kill "$launcher_pid"
wait "$launcher_pid" 2>/dev/null
launcher_pid=
for _ in {1..50}; do kill -0 "$second_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$second_pid" 2>/dev/null && fail "the second launch goes ahead once the first is done"
wait "$second_pid" || fail "the second launch succeeds"
pass "launches find their windows one at a time, and stop is not held up"
