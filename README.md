# MacBright

A menu bar app that pushes the MacBook Pro's Liquid Retina XDR display past its
normal 500-nit SDR limit, using the headroom macOS normally reserves for HDR.

## How it works

The XDR panel can do 1000 nits full-screen (1600 peak), but macOS caps regular
desktop content at 500. The extra range is only used for HDR (EDR) content:

1. **EDR trigger.** A 1×1 pt invisible window renders one black pixel into a
   Metal layer flagged `wantsExtendedDynamicRangeContent`. Its presence makes
   macOS switch the panel into EDR mode: the backlight is driven harder and SDR
   content is scaled down to compensate, so SDR white now sits below the
   panel's maximum. On this machine headroom goes from ×1.0 to ×3.2 within a
   second.
2. **Gamma boost.** The display's gamma table is multiplied by the boost
   factor. In EDR mode, output values above 1.0 land in that headroom, so all
   SDR content gets brighter.

## Follow ambient light

With **Follow ambient light** on, the slider becomes the *maximum* boost and the
ambient light sensor decides how much of it to use:

- The sensor is read from the IORegistry: the SPU HID device with usage page
  `0xFF00` / usage `4` publishes `CurrentLux`, the same value CoreBrightness
  uses (cross-checked against `corebrightnessdiag`'s `AggregatedLux`). Public
  IOKit only, no private frameworks.
- No boost below the *start* level (default 2,000 lux; indoors is usually
  100–500, overcast outdoors ~1,000–10,000, direct sun 30,000+). Above it, the
  boost follows an S-curve on a log scale and reaches the max at 10× the start
  level.
- Readings are smoothed: about 1–2 s to brighten when you step outside, about 5 s
  to dim when a shadow passes. Jitter under ×0.01 is ignored.
- When it isn't bright enough, the app goes to standby and leaves HDR mode
  completely. Hysteresis stops it flickering in and out near the threshold.

## Safety

- **Never exceeds macOS's headroom.** The effective factor is
  `min(slider, current EDR headroom)`, re-checked every second. macOS lowers
  that headroom itself when the panel gets hot or power-limited, and the boost
  follows it down. Slider max is ×2.0 (≈ the panel's 1000-nit full-screen rating
  at full brightness).
- **Only official APIs.** No private frameworks and no backlight overdrive. macOS
  and the display firmware keep their own thermal and power limits.
- **Pauses automatically** on thermal pressure (`serious`/`critical`), below 20%
  battery, in Low Power Mode, during sleep/display sleep and on user switch.
  An optional auto-off timer is available.
- **Crash-safe.** macOS discards custom gamma tables when the process exits, so
  quitting, crashing or `kill -9` all return the display to normal (verified).
- Changes fade in and out over ~0.3 s instead of jumping.

It does cost battery: a brighter backlight draws noticeably more power.

## Build

Requires macOS 14+ and the Xcode Command Line Tools.

```sh
./build.sh            # → build/MacBright.app
./build.sh --install  # also copies it to /Applications
```

The app icon is drawn in code by `Scripts/make-icon.swift`. To regenerate
`Resources/AppIcon.icns`, run
`swiftc Scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon`.

`build/MacBright.app/Contents/MacOS/MacBright --selftest` runs manual and automatic
boosts against the real display and light sensor (~12 s), checks the gamma table at each step, and exits 0 on success.

## Limitations

- Built-in display only (MacBook Pro 14"/16" M1 Pro/Max and later); external
  monitors are left alone.
- HDR video clips while boosting, because it shares the same headroom.
- Conflicts with other gamma-table apps (f.lux, Lunar, BetterDisplay's dimming).
- Gamma tables only take effect with 256 entries here. The display reports a
  capacity of 1024, but a full-size table with values above 1.0 is silently
  ignored.
