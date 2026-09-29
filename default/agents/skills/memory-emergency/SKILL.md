---
name: memory-emergency
description: >
  Respond to a memory emergency on this machine: RAM and swap filling up before
  systemd-oomd kills the desktop session. Use when started by omarchy-memory-watch
  or omarchy-agent-memory, when a "Memory brake" or "Memory agent" notification is
  acted on, or when asked what is eating memory and to fix it. Triggers: out of
  memory, OOM, swap full, system frozen or thrashing, oomd killed my session.
---

# Responding to a Memory Emergency

While RAM and swap are full, every minute counts. When systemd-oomd acts it kills
whole cgroups, and the one it picks can be the compositor's, which takes every open
window with it. Stop that with as little damage as possible.

## Tools

- `omarchy-memory-top`: this user's process groups by RAM + swap. A group is
  (cgroup, pgid). P means protected, T means stopped. `--json` lists every pid.
- `omarchy-memory-agents`: which AI agents (Claude Code, Codex, ...) started the
  heavy processes, charged per agent, with each agent's messaging route, transcript,
  and active subagents. `--json` for detail.
- `~/.local/state/omarchy/memory-watch/frozen.tsv`: groups the brake has already
  paused with SIGSTOP. `omarchy-memory-resume [name-regex]` resumes them.
- `~/.local/state/omarchy/memory-watch/agent-notes.log`: replies from AI agents
  (time, sender, text). They write to it with `omarchy-memory-note`.
- `omarchy-memory-message <name> "<message>"`: message a Claude Code session by
  name from any agent.
- `omarchy-memory-ask --background "<plan>" "<why>"`: asks the user with desktop
  toasts. The answer (approve, standdown, resolved, or timeout) lands in ask.out.
- `omarchy-notification-send "<headline>" "<body>"` for a plain FYI toast.
- Also: `free -m`, `/proc/pressure/memory`, `systemd-cgtop -m -n1`,
  `ps -o pid,ppid,pgid,rss,etime,args`, `journalctl --user --since -15min`.

## Steps

1. **Ask the AI agents first.** Memory spikes on a developer machine often come from
   AI agents running builds, editors, and test suites in parallel. Run
   `omarchy-memory-agents` right away. Within your first minute, message every agent
   charged with more than about 2G (or the top one if none is):
   - route `claude-peer`: if you are Claude Code, use your SendMessage tool with
     the agent's name (load it with ToolSearch `select:SendMessage` if it is
     deferred). Any other agent runs `omarchy-memory-message <name> "<message>"`,
     which relays it through a one-shot Claude call in about 10s.
   - route `none`: it can't be messaged. Read the tail of its transcript, if it
     has one, to learn what its processes are for.

   Say, with real numbers and pids: memory is critical and oomd is about to kill
   the desktop session. Their processes are using N G (list the top groups with
   pids). Right now they should kill parallel jobs they don't need, run only one
   heavy job at a time (including jobs their background subagents started, so
   tell those subagents too), and start nothing heavy until this clears. Within
   60s they should run `omarchy-memory-note '<what these processes are, which are
   safe to kill, what you did>'`. If they don't answer, the responder will kill
   restartable jobs itself. Mention any of their pids the brake has paused.

2. **Ask the user at the same time.** Run
   `omarchy-memory-ask --background "<plan>" "<why>"`. It returns at once, and the
   answer appears in `~/.local/state/omarchy/memory-watch/ask.out`. Don't
   background it yourself. Put the plan in plain words, e.g. "kill 2 headless
   editors started by claude-1234 (9G)".

3. **Watch and decide**, checking memory, agent-notes.log, and ask.out about every
   10s (empty ask.out means still waiting):
   - Memory is recovering because the agents are cleaning up: let them. Kill
     nothing, and resume paused groups once RAM available is back above ~25%.
   - An agent's note says which jobs are safe to kill or must be kept: follow it.
   - The user answers approve: carry out the plan. standdown: stop, leave paused
     groups paused, write the report, and send an FYI saying how to resume them.
     Take no further action.
   - Memory is growing fast and swap is above ~60%: pause the culprit now with
     `kill -STOP` on its pids and add it to frozen.tsv in the same format. Signal
     pids, never `kill -- -pgid`: a pgid can span cgroups, and the compositor's
     spans every app it launched.
   - Nobody (agents or user) has helped and memory is still high once the ask times
     out: apply the safe fix.

4. **Safe fix**, when nobody has helped:
   - OK to kill (SIGTERM the group, wait 5s, then SIGKILL): anything restartable
     that holds no unsaved user state. That covers compilers, linkers and build
     drivers (clang, gcc, ld, make, ninja, cargo, rustc, cmake, dotnet builds), test
     runners, headless scripts, background jobs started by agents, headless game
     engine or editor instances (cmdline flags like `-run=`, `-unattended`,
     `-nullrhi`, `--headless`), and leaking helpers such as MCP servers. Kill the
     largest or newest one first, not all of them.
   - Pause only, never kill: anything that may hold unsaved work or that the user is
     actively using. That covers windowed editors and IDEs, 3D and creative tools,
     browsers, and interactive agent sessions and their terminals.
   - Never touch: the compositor and session (Hyprland, Xwayland, quickshell, uwsm),
     systemd, pipewire, dbus, the display manager, omarchy-memory-watch itself, and
     games and their helpers (anything under Steam, Proton, or Wine). If a game is
     the culprit, only notify.
   - Kill the smallest thing that fixes it: one culprit group, not everything big.
   - After the fix, resume the groups that were paused but aren't the culprit, one
     at a time, checking memory after each one.
   - Never reboot, log out, use sudo, change system config, delete files, restart
     the killed job, or signal another user's processes.

5. **Verify.** Memory has only recovered when swap has stopped climbing and RAM
   available is above ~15%. If it hasn't, go back to step 1 once.

6. **Report.** Write the report file named in your prompt: a timeline, the culprit
   and how it started, which agents you messaged and what they answered (quote
   agent-notes.log), what you did and why, current metrics, and a one-line
   suggestion to prevent a repeat (for example, cap a build's parallel jobs). If
   the ask is still waiting, run `omarchy-memory-reply resolved` and give it about
   3s, so the user's toasts are dismissed. Then send one FYI toast that summarizes
   it and gives the report path. Keep your final answer short.
