# FrameFloat

**Who said FPS counters were a Windows thing? My Mac deserved one. So I built it.**

A tiny floating monitor. Live Hz, frame intervals, and a scrolling graph. Drag it anywhere. Keep it above everything. Let clicks pass through. Your screen, your rules.

*Measures display sync rate, not per-app FPS.*

## Get version 1.1.0

[Download FrameFloat.dmg](../../raw/refs/heads/main/FrameFloat.dmg), open it, and drag **FrameFloat.app** into **Applications**.

Apple Silicon · macOS 14+ · No dependencies · No screen recording or accessibility permissions.

Pick **Full**, **Mini**, or **Menu bar only** from the menu bar. The mini overlay shows just the Hz reading. With click-through on, the overlay fades to 20% opacity under the pointer and returns to full opacity when it leaves.

Menu bar only mode samples for about half a second every four seconds. A reading with `≈` shows the most recent sample. FrameFloat remembers your view, position, and click-through setting. Supports multiple desktops. Some exclusive fullscreen apps may cover the overlay.

## Build it

Install Apple's Command Line Tools, then run:

```sh
zsh build.command
```

## What the number means

FrameFloat measures this process's display-link callback cadence using `NSScreen.displayLink` and `CADisplayLink.timestamp`. The main reading averages up to 60 intervals. The 20-second graph plots the longest interval in each quarter-second sample so brief spikes stay visible. The dashed line shows the reference interval for the display mode, or the display's maximum rate when the mode does not report one.

It cannot measure another app's actual rendering FPS or the panel's instantaneous physical refresh rate. A stuttering app can still leave this counter at 60 Hz. Scheduling, power saving, and variable refresh policies can affect the reading.

No screen capture. No reading other apps. No network access.

The app is ad-hoc signed and has not been notarized by Apple. macOS may flag it as unverified when downloaded on another Mac.
