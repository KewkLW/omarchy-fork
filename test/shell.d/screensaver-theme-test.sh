#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

helper="$ROOT/bin/omarchy-screensaver-theme-effect"
screensaver="$ROOT/bin/omarchy-screensaver"

# Isolate HOME and XDG in two steps (single-line leaks XDG to the real home).
HOME=$(mktemp -d)
export HOME
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export PATH="$ROOT/bin:$PATH"

cleanup() { rm -rf "$HOME"; }
trap cleanup EXIT

# --- No theme screensaver: helper exits 1 ---

if "$helper" >/dev/null 2>&1; then
  fail "helper exits 0 when no theme screensaver exists"
fi
pass "helper exits non-zero when no theme screensaver directory exists"

# --- Empty effects file: helper exits 1 ---

theme_dir="$XDG_STATE_HOME/omarchy/current/theme/screensaver"
mkdir -p "$theme_dir"
touch "$theme_dir/effects"

if "$helper" >/dev/null 2>&1; then
  fail "helper exits 0 on empty effects file"
fi
pass "helper exits non-zero on empty effects file"

# --- Comments and blank lines are skipped ---

cat >"$theme_dir/effects" <<'EOF'
# This is a comment

  # indented comment
EOF

if "$helper" >/dev/null 2>&1; then
  fail "helper exits 0 on effects file with only comments"
fi
pass "helper skips comments and blank lines"

# --- Valid effect line resolves correctly ---

cat >"$theme_dir/test-art.txt" <<'EOF'
 ████
██  ██
 ████
EOF

cat >"$theme_dir/effects" <<'EOF'
# Horde Blood Rain
test-art.txt matrix --rain-color ff0000 --rain-time 18
EOF

output=$("$helper")
art_line=$(head -1 <<<"$output")
rest=$(tail -n +2 <<<"$output")

if [[ $art_line != "$theme_dir/test-art.txt" ]]; then
  fail "helper resolves art path (got: $art_line, expected: $theme_dir/test-art.txt)"
fi
pass "helper resolves relative art path to absolute"

expected_rest="matrix
--rain-color
ff0000
--rain-time
18"
if [[ $rest != "$expected_rest" ]]; then
  fail "helper outputs effect args one-per-line (got: $rest)"
fi
pass "helper outputs effect and flags one per line"

# --- Missing art file: helper exits 1 ---

cat >"$theme_dir/effects" <<'EOF'
nonexistent.txt burn --starting-color 331100
EOF

if "$helper" >/dev/null 2>&1; then
  fail "helper exits 0 when art file does not exist"
fi
pass "helper exits non-zero when art file is missing"

# --- Multiple lines: picks one ---

cat >"$theme_dir/another.txt" <<'EOF'
ART
EOF

cat >"$theme_dir/effects" <<EOF
test-art.txt matrix --rain-color ff0000
another.txt burn --starting-color 331100
EOF

output=$("$helper")
art_line=$(head -1 <<<"$output")
if [[ $art_line != "$theme_dir/test-art.txt" && $art_line != "$theme_dir/another.txt" ]]; then
  fail "helper picks from available effects (got: $art_line)"
fi
pass "helper picks a valid effect from multiple lines"

# --- Static: omarchy-screensaver calls the helper and still has --random-effect ---

grep -q 'omarchy-screensaver-theme-effect' "$screensaver" ||
  fail "omarchy-screensaver calls the theme effect helper"
pass "omarchy-screensaver calls omarchy-screensaver-theme-effect"

grep -q -- '--random-effect' "$screensaver" ||
  fail "omarchy-screensaver still contains --random-effect fallback"
pass "omarchy-screensaver retains --random-effect fallback"
