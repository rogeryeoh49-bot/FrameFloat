# FrameFloat

**Who said FPS counters were a Windows thing? My Mac deserved one. So I built it.**

A tiny floating monitor. Live Hz, frame intervals, and a scrolling graph. Drag it anywhere. Keep it above everything. Let clicks pass through. Your screen, your rules.

*Measures display sync rate, not per-app FPS.*

## Get it

[Download FrameFloat.dmg](../../raw/refs/heads/main/FrameFloat.dmg), open it, and drag **FrameFloat.app** into **Applications**.

Apple Silicon · macOS 14+ · No dependencies · No screen recording or accessibility permissions.

Use the menu bar to hide the overlay, enable click-through, choose a display, or quit. Position is saved. Supports multiple desktops; some exclusive fullscreen apps may cover the overlay.

## Build it

Install Apple's Command Line Tools, then run:

```sh
zsh build.command
```

## What the number means

FrameFloat measures this process's display-link callback cadence using `NSScreen.displayLink` and `CADisplayLink.timestamp`. It shows Hz, the corresponding interval in ms, and a 20-second graph.

It cannot measure another app's actual rendering FPS or the panel's instantaneous physical refresh rate. A stuttering app can still leave this counter at 60 Hz. Scheduling, power saving, and variable refresh policies can affect the reading.

No screen capture. No reading other apps. No network access.

The app is ad-hoc signed and has not been notarized by Apple. macOS may flag it as unverified when downloaded on another Mac.
