# Screen Dimmer — Plasma 6 widget

A KDE Plasma 6 widget that dims each screen in software, **below the minimum of its
backlight**. Useful for external monitors controlled over DDC/CI that are still too bright
at 0%.

The hardware brightness stays where it is: the "Brightness and Color" widget keeps
controlling the monitor over DDC/CI. Screen Dimmer adds a second, software level on top.

## How it works

KWin (6.6.1 and later) already has a per-screen software dimming factor, `dimming`. With a
DDC/CI monitor it is **never sent to the monitor**: KWin applies it in its color pipeline,
the same one used by Night Light. So it costs about nothing, needs no overlay window, and
full-screen games keep direct scanout when the driver allows it.

The catch: powerdevil writes `dimming` back to 100% on every brightness change and when
the screen comes back from idle dimming. So there are two parts:

- **`screen-dimmer` service** (`daemon/`, C++ with libkscreen): watches the screens and
  puts the chosen level back whenever someone else changes it. It follows powerdevil's
  idle dimming: when powerdevil dims to 30%, the screen goes to 30% of your level. It only
  reacts to events, with no timers or polling. When it stops, every screen goes back to 100%.
- **Widget** (`package/`): one slider per screen. It writes the levels to a file and the
  service applies them right away.

Files in `$XDG_RUNTIME_DIR/screen-dimmer/` (a tmpfs, so **after a reboot everything starts
again from 100%**):

- `levels`: written by the widget, one `<connector> <0-100>` per line
- `state`: written by the service, one `<connector>\t<name>\t<level>\t<dimming>\t<priority>` per line

## Using it

- **Click**: opens the sliders, one per screen.
- **Scroll on the icon**: ±5% on the main screen.
- **Middle click**: every screen back to 100%.
- While a screen is dimmed, the icon shows the darkest level.

## Limits

- **0% is not black.** KWin moves the white level from 200 to 5 nits of reference, so 0%
  leaves about 2.5% of the light the monitor gives out. You can never end up with a
  black screen by mistake.
- **Changes are gradual.** KWin animates dimming: going darker takes about 2 seconds from
  100% to 0%.
- **Screenshots are not dimmed**, because dimming is applied only on the way to the screen.
- Only Wayland. It needs KWin with `dimming` support (Plasma 6.6.1 or later).

## Requirements

- KDE Plasma 6.6.1 or later on Wayland (tested on 6.8.0)
- To build: `cmake`, a C++20 compiler, Qt 6 (Core, Gui), libkscreen (`KF6Screen`), all
  already present on a standard Plasma install plus `base-devel`

## Installation

```sh
./install.sh
```

It builds the service, installs it to `~/.local/bin/` and `~/.config/systemd/user/`,
enables it, and installs the widget. No sudo. Then: right-click the panel → Add Widgets →
"Screen Dimmer".

## Uninstalling

```sh
./uninstall.sh
```

It stops the service (screens go back to 100%) and removes the service and the widget.

## Problems

- **The widget says "Service not running"**: `systemctl --user status screen-dimmer` and
  `journalctl --user -u screen-dimmer`.
- **"dimming keeps being changed by another program" in the journal**: another program is
  setting `dimming` at the same time. The service pauses for a few seconds so it doesn't
  fight it.
- **Check the current values**: `kscreen-doctor -o | grep Brightness` shows the hardware
  brightness and the dimming of each screen.

## License

MIT
