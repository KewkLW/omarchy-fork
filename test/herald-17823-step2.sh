mkdir -p ~/bn/default/hypr/apps && cp default/hypr/apps/battlenet.lua ~/bn/default/hypr/apps/
sed -i "/bootstrap.lua/a package.path = \"$HOME/bn/?.lua;\" .. package.path" ~/.config/hypr/hyprland.lua
hyprctl reload && hyprctl configerrors

