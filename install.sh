#!/bin/sh
# Builds the service and installs (or updates) service and widget for the current user. No sudo.
set -e
cd "$(dirname "$0")"

cmake -S daemon -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build

install -Dm755 build/screen-dimmer "$HOME/.local/bin/screen-dimmer"
install -Dm644 systemd/screen-dimmer.service "$HOME/.config/systemd/user/screen-dimmer.service"
systemctl --user daemon-reload
systemctl --user enable screen-dimmer.service
systemctl --user restart screen-dimmer.service

if kpackagetool6 -t Plasma/Applet --show io.github.andry360.screendimmer >/dev/null 2>&1; then
    kpackagetool6 -t Plasma/Applet --upgrade package
else
    kpackagetool6 -t Plasma/Applet --install package
fi
echo "Done. Right-click the panel -> Add Widgets -> 'Screen Dimmer'."
