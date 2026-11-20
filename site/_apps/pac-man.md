---
name: PAC-MAN
platform: ios
kind: game
reports:
  - date: 2026-10-30
    bridge32: "955769ef"
    guest: armv6
    level: 1
    source: commit
    notes: Runs through its static initializers and stops at objc_msgSend.
  - date: 2026-10-31
    bridge32: "e3754bff"
    app_version: "1.0.2"
    level: 2
    source: commit
    notes: Reaches its title screen.
  - date: 2026-11-03
    bridge32: "10ce1d98"
    guest: armv6
    app_version: "1.0.2"
    level: 3
    source: readme
    notes: Runs, with touch and audio.
---
