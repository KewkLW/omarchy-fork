echo "Link the memory-emergency skill for the memory watchdog's AI responder"

# Skills are linked by omarchy-provision-user, which only runs once, so existing
# installs need the new one linked here, into the same places. The watchdog
# itself is opt-in (omarchy toggle memory-watch), so nothing is turned on.

skill="$OMARCHY_PATH/default/agents/skills/memory-emergency"

if [[ -d $skill ]]; then
  for skills_dir in ~/.agents/skills ~/.claude/skills ~/.codex/skills ~/.pi/agent/skills ~/.gemini/config/skills ~/.hermes/skills; do
    mkdir -p "$skills_dir"
    ln -sfn "$skill" "$skills_dir/memory-emergency"
  done
  # Hermes profiles only where they already exist, as provisioning does.
  if [[ -d ~/.hermes/profiles ]]; then
    for profile in ~/.hermes/profiles/*/; do
      [[ -d $profile ]] || continue
      mkdir -p "$profile/skills"
      ln -sfn "$skill" "$profile/skills/memory-emergency"
    done
  fi
fi
