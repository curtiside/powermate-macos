# powermate-macos

A tiny, **driver-free** way to use a **Griffin PowerMate** USB knob to control
volume, mute, media, and output-device switching on modern macOS (Apple Silicon
& Intel).

Griffin is long gone and the original PowerMate software is a dead kernel
extension that won't load on current macOS — so a lot of people have a perfectly
good knob that no longer does anything. This reads the PowerMate as a plain USB
HID device in **userspace** (`IOHIDManager`) — no kext, no background bloat — and
maps its gestures to built-in audio/media actions.

Out of the box (no config needed):

- **Turn** → volume up / down
- **Press** → mute toggle

And with an optional [config file](#gestures--config) you can also map **double-click**,
**long-press**, and **press-and-turn** to actions like play/pause, next/previous
track, and switching the output device. By default it controls your **current
default output device** (and follows you when you switch outputs), so it just
works. MIT licensed.

**How this differs from other PowerMate tools:** it's fully self-contained — one
small binary that both reads the knob *and* performs the actions itself, with a
plain-text config file (no [Hammerspoon](https://www.hammerspoon.org/) or other
runtime to install and script). The trade-off: a fixed built-in action set (not
arbitrary scripting) and USB-only. If you want per-app scripting or the Bluetooth
model, a Hammerspoon-based tool like [cedstrom/powermate-osx](https://github.com/cedstrom/powermate-osx)
may fit better.

## Supported hardware
This targets the **USB (wired) PowerMate** — Griffin VID `0x077d` / PID `0x0410`,
which macOS enumerates as a USB HID device. The later **Bluetooth PowerMate is a
BLE device, not USB HID, and is not supported** here (it needs a completely
different CoreBluetooth input path). Contributions welcome if you have one to test.

## Requirements
- macOS 11 or later (universal binary)
- Xcode Command Line Tools (`swiftc`) to build
- **Input Monitoring** permission for the binary (macOS gates HID input)

## Build & try
```sh
make            # builds a universal, ad-hoc-signed binary at build/powermate
make run        # run it: turn the knob (volume), press (mute)
```
First run needs Input Monitoring: **System Settings → Privacy & Security → Input
Monitoring** → add your terminal (for `make run`) or `/usr/local/bin/powermate`
(for the installed agent).

## Install as a login agent
```sh
make install
```
Installs `/usr/local/bin/powermate` (`sudo` is needed only for that) + a
**per-user** LaunchAgent in `~/Library/LaunchAgents` so the knob works at every
login. The agent logs to `~/Library/Logs/powermate.log`. Grant Input Monitoring
to `/usr/local/bin/powermate`, then:
```sh
launchctl kickstart -k gui/$(id -u)/io.github.curtiside.powermate
```
(Upgrading from an older version that installed the agent for all users in
`/Library/LaunchAgents`? `make install` migrates it automatically.)
Uninstall with `make uninstall` (removes the binary and LaunchAgent; your config
at `~/.config/powermate/` is left in place — `rm -rf ~/.config/powermate` to
remove it too).

## Gestures & config

All mappings live in a local config file. **If no config file exists, the
defaults are exactly `turn = volume`, `click = mute`, everything else off** — the
classic knob, no config required.

```sh
make config     # copies powermate.conf.example -> ~/.config/powermate/powermate.conf
                # (won't overwrite an existing one)
```
Edit it and restart the agent: `launchctl kickstart -k gui/$(id -u)/io.github.curtiside.powermate`.
Override the location with `POWERMATE_CONFIG=/path/to/file`.

**Gestures** (config keys): `turn_cw` `turn_ccw` `click` `double_click`
`long_press` `press_turn_cw` `press_turn_ccw`

**Actions** (values): `volume_up` `volume_down` `mute_toggle` `play_pause`
`next_track` `previous_track` `output_cycle` `none`

Settings: `device` (name substring, or `default`), `step` (volume per detent),
`long_press_ms`, `double_click_ms`.

> **Click latency:** a plain `click` fires **instantly** as long as
> `double_click`, `long_press`, and both `press_turn_*` are unmapped (the
> default). Mapping any of those forces the tool to wait briefly to tell a single
> click apart from a double / hold / press-and-turn, so the click action gets a
> small delay. Map them only if you want them.

> **Permissions:** `volume_*`, `mute_toggle`, and `output_cycle` use the CoreAudio
> API and need only Input Monitoring. `play_pause` / `next_track` /
> `previous_track` synthesize media keys and may prompt for **Accessibility**
> the first time they fire.

Notes: `output_cycle` skips virtual sinks (Zoom/Teams-style loopback devices)
and logs each switch to `~/Library/Logs/powermate.log`; AirPlay and aggregate
devices are included. Config typos are safe — unknown keys, unknown actions, and
out-of-range values are warned about in the log and ignored (they never activate
a gesture or add click latency), and the config is validated by `make test`.

You can also pin the target device without a config file via env vars (handy in
the plist's `EnvironmentVariables`):

| Env var | Meaning | Default |
|---|---|---|
| `POWERMATE_CONFIG` | path to the config file | `~/.config/powermate/powermate.conf` |
| `POWERMATE_DEVICE` | output device name substring to control | current default output |

e.g. pin it to specific speakers: `POWERMATE_DEVICE="Studio Display" make run`.

## Other modes
```sh
make list         # list HID devices (find your knob or other devices' VID/PID)
make watch        # print the knob's raw HID reports (debug)
make test         # run the built-in config-parser self-tests
powermate --watch 0x0b0e 0x2e50   # watch ANOTHER device's raw reports
                                  # (VID PID — decimal or 0x-hex; great for
                                  # catching a dongle sending volume events)
powermate --version
```
For reference, the PowerMate's input report is `[button, signed-rotation, …]`
(byte 0 = button 0/1, byte 1 = signed rotation delta).

## Bonus: stop a headset/dongle from hijacking your volume

If you have a Bluetooth headset dongle (Jabra, Poly, …), you may notice your
**Mac's output volume jumps — and your speakers click — every time you join or
leave a call**. That's the dongle sending HID `volume_decrement`/`increment`
events on "call mode," which macOS applies to your **current default output
device** (not the headset). Its physical volume buttons hit the wrong device for
the same reason.

`karabiner-block-volume.sh` (needs [Karabiner-Elements](https://karabiner-elements.pqrs.org/)
and `jq`) makes Karabiner swallow that device's volume events so they stop moving
your output:

```sh
# find the device's vendor/product IDs:
make list
# then block its volume events — decimal or 0x-hex both work
# (example: Jabra Link 390 = 2830/11856 = 0x0b0e/0x2e50):
make setup-karabiner KB="2830 11856 Jabra Link 390"
```

Then, in **Karabiner → Settings → Devices**, make sure that device has **"Modify
events"** checked — Karabiner monitors but won't *seize* some non-keyboard devices
without it (this is the step everyone misses).

This pairs naturally with the knob: the PowerMate controls volume through the
audio API (not volume keys), so blocking a device's volume keys **doesn't** affect
the knob — you get a real volume knob *and* no more surprise volume jumps.

## Troubleshooting

**First stop: the log.** The installed agent writes everything (connects,
disconnects, config warnings, permission hints, `output_cycle` switches) to
`~/Library/Logs/powermate.log`:
```sh
tail -f ~/Library/Logs/powermate.log
```

**`make list` / `make watch` doesn't show the knob at all.** The PowerMate is a
**USB 1.1** device and is surprisingly picky about which port or hub it enumerates
on — some USB-3 / powered-hub / dock ports won't bring it up (no blue light, or a
light but no HID device). **Try a different port**, ideally a direct one or a
plain USB-2 hub, until the light comes on *and* it appears in `make list`.

**The knob is detected but nothing happens.** macOS gates HID input behind
**Input Monitoring**. Grant it to the right thing — your terminal for `make run`,
or `/usr/local/bin/powermate` for the installed agent — then restart:
```sh
launchctl kickstart -k gui/$(id -u)/io.github.curtiside.powermate
```

**Is the agent actually running?**
```sh
launchctl print gui/$(id -u)/io.github.curtiside.powermate | grep -E 'state|pid'
```

**A media action (`play_pause`/`next_track`/`previous_track`) does nothing.**
These synthesize media keys; if they silently no-op, grant the binary
**Accessibility** (System Settings → Privacy & Security → Accessibility) and
restart the agent. Volume/mute/output actions use the audio API and aren't
affected.

**Config changes aren't taking effect.** The config is read at startup only —
restart the agent with the `kickstart` command above after editing. If a value
looks ignored, check the log: unknown keys/actions and out-of-range values are
warned about and skipped.

**The knob stopped working after updating from source.** The binary is ad-hoc
signed, so its signature changes on every rebuild — macOS may silently drop the
old **Input Monitoring** grant. Open System Settings → Privacy & Security →
Input Monitoring, remove `/usr/local/bin/powermate` (−), re-add it (+), then
`kickstart` the agent.

## How it works / why no kext
`IOHIDManager` opens the PowerMate (Griffin VID `0x077d`, PID `0x0410`) in
userspace and receives its input reports directly. Gestures (turn, click,
double-click, long-press, press-and-turn) are decoded from those reports and
dispatched to built-in actions per your [config](#gestures--config): volume and
mute via CoreAudio (`kAudioDevicePropertyVolumeScalar` / mute), output switching
via the default-device property, and media control via synthesized media keys.
No kernel extension, no system extension, nothing to approve beyond Input
Monitoring (plus Accessibility only if you use media actions).

## License
MIT — see [LICENSE](LICENSE). Not affiliated with Griffin Technology.
"PowerMate" is used only to identify the hardware.
