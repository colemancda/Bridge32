---
name: Halo
platform: macos
kind: game
reports:
  - date: 2026-11-09
    bridge32: "6942f0ed"
    pr: 2
    guest: i386
    level: 1
    source: pr
    notes: Gets through start-up and its system checks, then stops at its own disc check and crashes on the way out.
  - date: 2026-11-19
    bridge32: "afd278a8"
    pr: 16
    guest: i386
    app_version: "1.0.9"
    level: 3
    source: pr
    notes: Gets through its product-key dialog and graphics settings to the main menu, in a window. Input on the menu isn't tried.
    screenshots:
      - url: https://github.com/user-attachments/assets/7434159c-49e2-4103-b898-9fa33bdf5c69
        caption: Main menu in a window
  - date: 2026-11-19
    bridge32: "4a2c1ce5"
    pr: 21
    guest: i386
    level: 4
    source: pr
    notes: Starts the campaign and plays the opening of The Pillar of Autumn, with mouse look and walking. Firing and the rest of the level aren't checked.
    screenshots:
      - url: https://github.com/user-attachments/assets/858b3a53-d708-48de-8e9a-36355aa2458b
        caption: The Pillar of Autumn's cryo room
  - date: 2026-11-19
    bridge32: "db39d855"
    pr: 23
    guest: i386
    level: 4
    source: pr
    notes: Plays its sound effects through the Sound Manager in The Pillar of Autumn. The sound hasn't been listened to.
---

- In its menus only keypad Enter (fn-Return) is Enter; Return works in its text boxes.
- `B32_AUTO_OK=1` presses the OK button of its settings window, for runs with no one at the screen.
- Re-sign the wrapped app without the sandbox (`tools/update-shell.sh` does); in a container,
  Halo refuses its Documents folder for the periods in the container's name.
- Its intro movies (QuickTime) aren't played.
