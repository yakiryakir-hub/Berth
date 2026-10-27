# Changelog

All notable changes to Berth (a fork of Moorage by Skyler Schoos).

## [0.1.0] - Berth

- Renamed Moorage to Berth; mounts at ~/Berth; bundle id com.yakir.berth.
- USB transport rewritten on IOUSBLib (IOUSBInterfaceInterface942) via a small C shim (CBerthUSB); fixes Pixel mounting.
- Session recovery: a device that re-enumerates after mounting is detected by registry entry ID and reconnected; dead sessions are dropped instead of failing every request with 503.
- Single-flight connect; no USB reset; no pre-session drain by default; bounded retries.
- Menu shows "Phone is locked or not sharing files" while a mounted phone shares no storage; clears and returns live on USB mode changes.
- Faster plug/unplug: plug-in to usable volume about 0.9 s (was about 1.9 s), USB open 374 to 127 ms, unmount 26 ms, unplug confirmed in 0.6 s (time-based, not event-count), tighter mount polling, shorter retry backoff, rescan after wake from sleep. Per-step timings are written to the log ("timing:" lines).
- Copy Diagnostics menu item (redacted report for bug reports).
- New original app icon: a shooting star in Pixel-style colours on Samsung-style blue.
- Friendly device names; Samsung Galaxy Tab A11 and Pixel 10 Pro verified.

## Moorage history

- Working end to end against a real Kindle Paperwhite: auto-mount on plug,
  browse, byte-exact reads, capacity display, auto-opened Finder window.
- Final architecture (third attempt): zero extensions. The menu bar app
  serves the MTP tree over a token-guarded localhost WebDAV server (DavKit,
  pure Swift) and mounts it with the system's mount_webdav. FSKit (Apple bug
  on macOS 26) and File Provider (appex launch requires Xcode target wiring)
  are documented dead ends in docs/PITFALLS.md.
- MTPKit: pure Swift MTP/PTP over IOUSBHost. Kindle quirks handled:
  vendor-specific MTP interface detection, strict transaction-ID-0 outside
  sessions, stale-pipe drain on connect. FIFO bus lock makes multi-phase
  transactions atomic under webdavfs's concurrent requests (actor isolation
  alone reenters at every await).
- Full write lifecycle verified on-device: paste, rename, delete, mkdir,
  nested ops, 2 MB binary round-trip byte-identical.
- Single-storage devices (Kindle) mount the storage as the volume root; no
  read-only "Internal Storage" wrapper to trip Finder pastes.
- Mount robustness: retry with backoff at attach (Image Capture races),
  stale-mount sweep before mounting, debug log at ~/Library/Logs/Moorage.log.
- Finder junk (.DS_Store, ._AppleDouble) swallowed in RAM, never sent to
  the device.
- MoorageSelfCheck: 50 checks covering MTP codec and the WebDAV server,
  plus `scan`, `probe [read]`, and `--serve-demo` (mountable in-memory
  device) diagnostics.
- Project scaffold: design doc, pitfall map, MIT license.
