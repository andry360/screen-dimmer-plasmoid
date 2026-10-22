#!/bin/sh
# Stopping the service puts every screen back to 100%.
systemctl --user disable --now screen-dimmer.service
rm -f "$HOME/.config/systemd/user/screen-dimmer.service" "$HOME/.local/bin/screen-dimmer"
systemctl --user daemon-reload
rm -rf "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/screen-dimmer"
kpackagetool6 -t Plasma/Applet --remove io.github.andry360.screendimmer
