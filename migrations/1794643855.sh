echo "Link the disk-triage skill for the disk watchdog's AI responder"

# Skills are linked by omarchy-provision-user, which only runs once, so existing
# installs need the new one linked here, into the same places. The watchdog
# itself is opt-in (omarchy toggle disk-watch), so nothing is turned on.

skill="$OMARCHY_PATH/default/agents/skills/disk-triage"

if [[ -d $skill ]]; then
  for skills_dir in ~/.agents/skills ~/.claude/skills ~/.codex/skills ~/.pi/agent/skills ~/.gemini/config/skills ~/.hermes/skills; do
    mkdir -p "$skills_dir"
    ln -sfn "$skill" "$skills_dir/disk-triage"
  done
  if [[ -d ~/.hermes/profiles ]]; then
    for profile in ~/.hermes/profiles/*/; do
      [[ -d $profile ]] || continue
      mkdir -p "$profile/skills"
      ln -sfn "$skill" "$profile/skills/disk-triage"
    done
  fi
fi
