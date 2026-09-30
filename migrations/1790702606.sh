echo "Link the omarchy-app agent skill for building apps"

# omarchy-provision-user links every skill, but only once per user, so
# existing installs get the new one here, in the same places.
skill="$OMARCHY_PATH/default/agents/skills/omarchy-app"

if [[ -d $skill ]]; then
  for skills_dir in ~/.agents/skills ~/.claude/skills ~/.codex/skills ~/.pi/agent/skills ~/.gemini/config/skills ~/.hermes/skills; do
    mkdir -p "$skills_dir"
    ln -sfn "$skill" "$skills_dir/omarchy-app"
  done

  if [[ -d ~/.hermes/profiles ]]; then
    for profile in ~/.hermes/profiles/*/; do
      [[ -d $profile ]] || continue
      mkdir -p "$profile/skills"
      ln -sfn "$skill" "$profile/skills/omarchy-app"
    done
  fi
fi
