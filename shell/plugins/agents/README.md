# Agents

One bar icon and one panel for every AI coding subscription on the machine.
The panel is strictly a display: it watches the usage records that
`omarchy-agent-usage-update` writes to `~/.local/state/omarchy/agents/usage/`
and draws whatever appears there. `Panel.qml` owns the bar button and the
popup; `Main.qml` discovers and watches the records (and handles the optional
cross-device aggregation); `Agent.qml` is the per-record file watcher.

## Panel

- **Hero** — the mark, the tool, and the plan it runs on ("Max 20x", "Pro").
  Auth and endpoint problems replace the plan line and repeat in a card.
- **Subscription switch** — one chip per enabled agent (`h`/`l` or click).
  It appears only when more than one agent is enabled.
- **Limits** — the percentage of each allowance used, a matching meter, and
  the time until the session or weekly window resets.
- **Balance** — prepaid agents report a credit ledger instead of limits:
  remaining credit, a fuel-gauge meter that drains toward empty, and
  funded-versus-spent detail.
- **Tokens by day** — one row per day for the last week: day, bar, tokens, with today
  bolded at the bottom. Hover today for its prompt and session count.
- **Tokens by model** — tokens per model with the bar behind each row scaled
  to the heaviest model,
  the same way the weekly chart scales to its busiest day. Hover for the
  input / output / cache split.
- **Telemetry line** (Claude tabs, only with telemetry on), under the limits —
  one line: `Today $X API-equiv · N live · open stats ›`. It turns urgent and
  counts them when a live session is flagged looping, so a stuck slot shows
  without opening anything. Click it (or press `s`) for the
  [agent stats window](#agent-stats-window). See
  [Claude Code telemetry](#claude-code-telemetry).

## Agent stats window

Right-click the bar icon, click the telemetry line, press `s` in the panel,
or run `omarchy-launch-agent-stats` (bindable; `--toggle` closes it when it
already has focus). It is an ordinary app window, app id
`org.omarchy.agent-stats`, floated and centered by a rule in
`default/hypr/apps/agents.lua`; move, resize, tile or close it like any
other. `shell/agent-stats.qml` runs as its own Quickshell process (the
launcher sets `QS_APP_ID`) around `Stats.qml`, with the panel's theme,
fonts and controls, and the process ends when the window closes.

An account switch like the panel's, a range of 7 days, 30 days or all, a
Cost / Tokens switch (key `t`) that the bounty and agent views follow, and:

- **Tiles** — today and the last 7 days at API list prices with their
  tokens, live sessions, and how many of them are looping.
- **Live sessions** — every field the receiver reports, one row each, titled
  by agent name, project and bounty; a looping one is drawn urgent with its
  reason.
- **Cost per day** and **tokens per day**, stacked by model (the top three
  and Other, in steps of the theme's foreground and accent).
- **Cost (or tokens) by bounty** — the top 12 bounties or tickets in the
  range, each under its project.
- **Cost (or tokens) per bounty by model** — a model's tagged spend over the
  bounties it worked. Telemetry does not know which bounties landed, so this
  is per bounty worked, not per landing.
- **Agents** — one row per named agent over the range (project, model, cost,
  tokens, requests, sessions, live or idle), filterable by project. Click a
  row to chart that agent alone, Ctrl+click to add others to the chart, `c`
  to clear; with nothing picked the chart shows the three biggest. One agent
  draws as bars per day, several as one line each.
- **Limits over time** — weekly and model-scoped weekly percentages as step
  lines, the 5-hour session as a faint area, with the panel's 90% line.

Keys: `h`/`l` account, `1` `2` `3` range, `t` cost or tokens, `c` clear the
picked agents, `r` refresh, `j`/`k` scroll, Esc closes. Everything comes from one call, `omarchy-agent-otel history
--range 7d|30d|all`, rerun every 30 seconds and when `summary.json` changes.

A subscription appears only when it is enabled in settings and has actually
recorded usage — on this machine or on a synced one. With one such agent
there is no switch row at all; with none, the module leaves the bar entirely
rather than sitting there with nothing to say. A CLI installed mid-session
shows up at the next refresh, so nothing polls the disk waiting for it.

That self-hiding is why the widget ships in the default bar layout: a machine
that has never run an AI coding agent draws nothing, and the icon arrives on
its own the first time a scan finds usage. Drop it with
`omarchy plugin disable omarchy.agents`.

## Data

Each agent is one JSON record in `~/.local/state/omarchy/agents/usage/`,
written by `omarchy-agent-usage-update`. That command runs one
`omarchy-agent-usage-<agent>` collector per agent; the widget invokes it
on its refresh timer and whenever you ask for a refresh, and picks up any
record that lands in the directory regardless of who wrote it.

Adding an agent therefore never touches this plugin: ship a collector that
prints the record contract (see the `claude` and `codex` collectors in
`bin/`), and the panel gains a tab. An `assets/<id>.svg` mark is optional —
with an `assets/<id>-light.svg` twin if the mark needs a dark variant for
light surfaces — and the bar glyph stands in when there is none.

| Collector | Limits | Local stats |
|---|---|---|
| `claude` | Anthropic's OAuth usage endpoint (5-hour session + 7-day weekly) | `~/.claude/projects` transcripts, opencode sessions on an Anthropic provider, plus `stats-cache.json` and `history.jsonl` as fallback |
| `codex` | The Codex app-server RPC | native Codex CLI session files (plus pi and opencode sessions) |
| `fireworks` | Estimated prepaid balance: configured funding minus rated account costs | Fireworks billing API, grouped by day and model for the last 30 days |

Claude tabs can also show Claude Code's own OpenTelemetry (live sessions,
cost per bounty and model), read from
`~/.local/state/omarchy/agents/otel/summary.json`, which
`omarchy-agent-otel` writes — see below.

Claude limits need a signed-in CLI; without credentials the panel says so and
falls back to local stats only. A non-default Claude directory is honored via
`CLAUDE_CONFIG_DIR`, Codex via `CODEX_HOME`. Fireworks reads
`FIREWORKS_API_KEY` and `FIREWORKS_ACCOUNT_ID` first, then
`~/.fireworks/auth.ini` (which `firectl set-api-key` creates), then the key
opencode stores in `~/.local/share/opencode/auth.json` when Fireworks is
signed in there.

### Claude Code telemetry

Claude Code can export OpenTelemetry, and `omarchy-agent-otel serve` is a
small receiver for it on `127.0.0.1:4318` (loopback only). It ships as
`omarchy-agent-otel.service` but is not enabled. To turn it on:

```bash
install -Dm644 "$OMARCHY_PATH/default/systemd/user/omarchy-agent-otel.service" \
  ~/.config/systemd/user/omarchy-agent-otel.service
systemctl --user daemon-reload
systemctl --user enable --now omarchy-agent-otel.service
```

and start Claude Code with:

```bash
CLAUDE_CODE_ENABLE_TELEMETRY=1
OTEL_LOGS_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
OTEL_EXPORTER_OTLP_PROTOCOL=http/json
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
```

Tag a run with `OTEL_RESOURCE_ATTRIBUTES=project=…,agent.name=…,bounty.id=…,bounty.slot=…,bounty.attempt=…`
(or `ticket=…`) to have its cost attributed. `project` keeps boards apart
(bounty and slot ids repeat from one board to the next: bounties and agents
are keyed `<project>/<id>`), and `agent.name` is the agent's name for the
project's life, so every agent must spawn with a specific, stable name. The
bounty board tags its slots this way from each slot's `name` in `board.json`;
`omarchy agent --project <p> --name <n>` (or `OMARCHY_PROJECT` and
`OMARCHY_AGENT_NAME` in the environment) tags a session started by hand. The receiver keeps only the
`api_request` and `tool_result` events, and of those only timestamps,
session and account ids, model, cost, token counts, tool name, success and
duration, plus those tags. Prompts are never logged: Claude Code redacts them
unless `OTEL_LOG_USER_PROMPTS=1`, and even then the receiver drops the field,
as it does tool inputs, error text, email and organization ids. Events land
in `~/.local/state/omarchy/agents/otel/events-YYYY-MM-DD.jsonl` (kept 14
days); every 10 seconds the receiver rewrites `summary.json` beside them when
it changed, which `Main.qml` watches. `omarchy-agent-otel status` prints it.

Accounts are matched by `oauthAccount.accountUuid`: `~/.claude.json` (or
`$CLAUDE_CONFIG_DIR/.claude.json`) is the `claude` tab, and each account in
`~/.config/omarchy/agents/claude-accounts.json` is `claude-<id>` via its own
`<dir>/.claude.json`. Every dollar figure is `cost_usd` as Claude Code
reports it — the API list price equivalent, not what a subscription bills.
A live session is marked looping when its last 12 tool calls were the same
tool with at least half failing, or when it made more than 40 tool calls in
five minutes with no API cost growth. With no `summary.json` the line is
not drawn at all.

### History

The 14 days of raw events are the only place telemetry is kept in detail;
two compact histories outlive them, are never pruned, and are what the stats
window draws:

| File | Written by | One line per |
|---|---|---|
| `~/.local/state/omarchy/agents/otel/history/YYYY-MM.jsonl` | `omarchy-agent-otel` | day × account: cost, tokens and requests in total, by model, by bounty and by named agent (each bounty and agent with its cost, tokens and requests by model) |
| `~/.local/state/omarchy/agents/history/limits-YYYY-MM.jsonl` | `omarchy-agent-limits-history`, after every record `omarchy-agent-usage-update` writes | change in an agent's limits: `ts`, `agent`, `session`, `weekly`, and model-scoped weekly percentages under `models` |

The receiver backfills the daily rollup from every event file still on disk
when it starts (and on `omarchy-agent-otel rollup`), then rewrites a day's
line at most once a minute while its totals change. Days whose event files
have aged out are left as last written. A limit refresh that reads the same
percentages as the agent's last line appends nothing; a refresh that could
not reach the limits endpoint records nothing either. Both stay in the
hundreds of kilobytes a month on a busy board.

### Fireworks balance

The collector first asks the account's `:getBalance` endpoint for the real
prepaid ledger. That endpoint exists but is permission-gated, and as of
August 2026 no console-issued API key passes it — Fireworks appears to
reserve it for the dashboard session. The probe stays because it is cheap
and the live figure lights up automatically if Fireworks ever opens it to
keys. Until then the collector falls back to estimating the balance from
configuration in `~/.config/omarchy/agents/fireworks.json`:

```json
{
  "accountId": "",
  "fundedAmount": 20,
  "fundedAt": "2026-07-01"
}
```

Set `fundedAmount` to the credits purchased and optionally `fundedAt` to the
purchase date; with no date, the collector uses the account creation time. It
subtracts rated account costs and the panel labels the result as estimated.
For a later top-up, increase `fundedAmount` by the new credit while keeping
the original `fundedAt`, so both the funding and spend still cover the same
period. `accountId` only matters when one API key can access several
accounts. Without a configured `fundedAmount` the tab still shows token
usage, just no balance. With a live ledger, `fundedAmount` is optional and
only adds the meter and the spent-of-funded line under the real figure.

## Interactions

- Bar icon: left = panel, right = [agent stats window](#agent-stats-window),
  middle = next subscription. The agent picker stays on
  SUPER+SHIFT+CTRL+A, and right-clicking a subscription tab still starts
  that provider's CLI.
- Panel: `h`/`l` switch subscription, `j`/`k` scroll, `r` or Enter refresh,
  `s` opens the stats window, Tab moves to the neighboring bar panel, Esc
  closes.
- IPC: `omarchy-shell omarchy.agents <open|close|toggle|refresh|next>`.

## Settings

Settings live in the widget's entry in `~/.config/omarchy/shell.json`. The
top-level keys can be set with
`omarchy bar set omarchy.agents <key> <value>`:

| Key | Default | What it does |
|---|---|---|
| `refreshIntervalSec` | `900` | How often the usage records regenerate |
| `syncMode` | `"Off"` | `"On"` writes this machine's snapshot and merges the others |
| `syncDir` | `""` | A folder synced by Syncthing, Dropbox, rsync, … |
| `syncFileName` | `<hostname>.json` | This machine's snapshot file |
| `syncDeviceId` | hostname | Stable device name inside the snapshot |

Numbers need `--json`, or they land in `shell.json` as strings:

```bash
omarchy bar set omarchy.agents refreshIntervalSec 300 --json
omarchy bar set omarchy.agents syncDir '~/Sync/agent-usage'
```

Per-agent enablement is nested, and `set` writes its key literally rather
than walking a dotted path — so pass the whole `providers` object as JSON (or
edit `shell.json` directly):

```bash
omarchy bar set omarchy.agents providers '{
  "claude": { "enabled": true },
  "codex": { "enabled": false },
  "fireworks": { "enabled": true }
}' --json
```

`enabled` defaults to `true` for every discovered agent; set it to `false` to
hide a subscription that is installed. Disabled agents are also skipped when
the records regenerate.

With `syncMode` on, every `*.json` snapshot in `syncDir` is merged, so today,
the last 7 days, and the all-time totals cover every machine you code on —
active days are unioned by date rather than summed. Rate limits stay
per-account and are never merged. A record may declare `"scope": "account"`
when its stats are account-global rather than machine-local (Fireworks'
billing API); those merge by taking the widest value instead of summing, so
the same account synced from two machines is not counted twice.

One caveat on "all-time": the Codex collector only reads native session files
touched in the last 30 days, and Fireworks requests the last 30 days from its
billing API, so their totals and day counts cover that window. Claude's cover
every transcript still on disk.
