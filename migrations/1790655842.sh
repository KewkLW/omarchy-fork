echo "Link the memory-emergency skill for the memory watchdog's AI responder"

# Skills are linked by omarchy-provision-user, which only runs once, so existing
# installs need the new one linked here. The watchdog itself is opt-in
# (omarchy toggle memory-watch), so nothing is enabled.

skill="$OMARCHY_PATH/default/agents/skills/memory-emergency"

if [[ -d $skill ]]; then
  for skills_dir in ~/.agents/skills ~/.claude/skills ~/.codex/skills ~/.pi/agent/skills; do
    mkdir -p "$skills_dir"
    ln -sfn "$skill" "$skills_dir/memory-emergency"
  done
fi

systemctl --user daemon-reload >/dev/null 2>&1 || true
