---
name: World of Goo
platform: macos
kind: game
reports:
  - date: 2026-11-18
    bridge32: "4ebc3106"
    pr: 7
    guest: ppc
    app_version: "1.30"
    level: 2
    source: pr
    notes: Gets through loading to its title screen and takes mouse input, at about 50 frames per second.
    screenshots:
      - url: https://github.com/user-attachments/assets/54ac58c7-42ce-4370-b5cf-83c03d06913f
        caption: Title screen
  - date: 2026-11-18
    bridge32: "d3479a33"
    pr: 8
    guest: ppc
    level: 4
    source: pr
    notes: Plays into the first level full screen, with mouse input and typing a name.
    screenshots:
      - url: https://github.com/user-attachments/assets/3bf6154c-5f9e-4433-bae9-e7a55d60815e
        caption: The first level's intro card
---

It runs full screen; `B32Windowed` or `B32_WINDOWED=1` gives it an ordinary window instead.
