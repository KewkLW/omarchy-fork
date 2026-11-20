python3 standin.py 4 6 &
until (( $(hyprctl clients -j | jq '[.[] | select(.class == "steam_app_battlenet")] | length') == 2 )); do sleep 0.1; done
addr=$(hyprctl clients -j | jq -r '.[] | select(.class == "steam_app_battlenet" and .title == "Battle.net") | .address')
hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })"
sleep 1; hyprctl activewindow -j | jq -r .title
sleep 4; hyprctl activewindow -j | jq -r .title

