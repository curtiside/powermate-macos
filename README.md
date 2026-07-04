# powermate-macos

A tiny, **driver-free** way to use a **Griffin PowerMate** USB knob as a volume
control on modern macOS (Apple Silicon & Intel).

Griffin is long gone and the original PowerMate software is a dead kernel
extension that won't load on current macOS — so a lot of people have a perfectly
good knob that no longer does anything. This reads the PowerMate as a plain USB
HID device in **userspace** (`IOHIDManager`) — no kext, no background bloat — and
maps it to your audio volume:

- **Turn** → volume up / down
- **Press** → mute toggle

By default it controls your **current default output device** (and follows you
when you switch outputs), so it just works. ~200 lines of Swift, MIT licensed.

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
Installs `/usr/local/bin/powermate` + a LaunchAgent so the knob works at every
login. Grant Input Monitoring to `/usr/local/bin/powermate`, then:
```sh
launchctl kickstart -k gui/$(id -u)/com.cidemaxio.powermate
```
Uninstall with `make uninstall`.

## Configure
| Env var | Meaning | Default |
|---|---|---|
| `POWERMATE_DEVICE` | output device name substring to control | current default output |
| `POWERMATE_STEP` | volume change per detent (0.0–1.0) | `0.03` |

e.g. pin it to specific speakers: `POWERMATE_DEVICE="Studio Display" make run`.
Add these to the plist's `EnvironmentVariables` for the installed agent.

## Other modes
```sh
make list         # list HID devices (find your knob or other devices' VID/PID)
make watch        # print the knob's raw HID reports (debug)
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
# find the device's vendor/product IDs (decimal):
make list
# then block its volume events (example: Jabra Link 390 = 2830 / 11856):
make setup-karabiner KB="2830 11856 Jabra Link 390"
```

Then, in **Karabiner → Settings → Devices**, make sure that device has **"Modify
events"** checked — Karabiner monitors but won't *seize* some non-keyboard devices
without it (this is the step everyone misses).

This pairs naturally with the knob: the PowerMate controls volume through the
audio API (not volume keys), so blocking a device's volume keys **doesn't** affect
the knob — you get a real volume knob *and* no more surprise volume jumps.

## How it works / why no kext
`IOHIDManager` opens the PowerMate (Griffin VID `0x077d`, PID `0x0410`) in
userspace and receives its input reports directly; rotation deltas and the button
are mapped to CoreAudio `kAudioDevicePropertyVolumeScalar` / mute on the target
device. No kernel extension, no system extension, nothing to approve beyond Input
Monitoring.

## License
MIT — see [LICENSE](LICENSE). Not affiliated with Griffin Technology.
"PowerMate" is used only to identify the hardware.
