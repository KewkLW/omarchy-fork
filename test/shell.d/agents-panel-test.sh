#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const panelSource = fs.readFileSync(root + '/shell/plugins/agents/Panel.qml', 'utf8')

assert(/function openStats\(\)/.test(panelSource), 'agents panel opens the stats window')
assert(/root\.bar\.run\("omarchy-launch-agent-stats"\)/.test(panelSource), 'agents panel opens the stats window through its launcher')
assert(/if \(buttonCode === Qt\.RightButton\) root\.openStats\(\)/.test(panelSource), 'agents right click opens the stats window')
assert(/else if \(buttonCode === Qt\.MiddleButton\) root\.selectProvider\(root\.providerIndex \+ 1\)/.test(panelSource), 'agents middle click still advances the subscription')
assert(/else root\.toggle\(\)/.test(panelSource), 'agents left click still toggles the panel')
assert(!/if \(buttonCode === Qt\.RightButton\) root\.refreshNow\(\)/.test(panelSource), 'agents right click no longer refreshes')
assert(!/COST BY BOUNTY|LIVE SESSIONS|COST BY MODEL|API EQUIVALENT/.test(panelSource), 'agents dropdown leaves telemetry detail to the stats window')
assert(/open stats ›/.test(panelSource), 'agents dropdown keeps one telemetry line that opens the stats window')

const launcher = fs.readFileSync(root + '/bin/omarchy-launch-agent-stats', 'utf8')
assert(/^# omarchy:summary=/m.test(launcher), 'stats launcher has a command summary')
assert(/APP_ID=org\.omarchy\.agent-stats/.test(launcher) && /QS_APP_ID="\$APP_ID"/.test(launcher), 'stats window runs under its own app id')
assert(/shell\/agent-stats\.qml/.test(launcher), 'stats launcher runs the stats window config')
assert(fs.existsSync(root + '/shell/agent-stats.qml'), 'stats window config sits beside shell.qml')
const rules = fs.readFileSync(root + '/default/hypr/apps/agents.lua', 'utf8')
assert(/\^org\.omarchy\.agent-stats\$.*float = true/.test(rules), 'stats window floats by its app id')
JS
