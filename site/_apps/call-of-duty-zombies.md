---
name: "Call of Duty: Zombies"
platform: ios
kind: game
reports:
  - date: 2026-10-31
    bridge32: "7b686cc0"
    pr: 24
    level: 2
    source: commit
    notes: Reaches its title screen.
    screenshots:
      - url: https://github.com/user-attachments/assets/20e7e9dc-498c-4e04-80f9-c4295908d069
        caption: Title screen, from a later run
  - date: 2026-10-31
    bridge32: "2e48fa13"
    app_version: "1.5.0"
    level: 4
    source: commit
    notes: Plays with a game controller.
---

The controller mapping is a module of its own, ported from codwawzpc. A later commit
(`4eb29c36`) lets the controller navigate the menus and pause the game with Options.
