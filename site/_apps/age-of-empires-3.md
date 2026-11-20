---
name: Age of Empires III
platform: macos
kind: game
reports:
  - date: 2026-11-18
    bridge32: "6b8782ac"
    pr: 9
    guest: i386
    app_version: "1.0.5"
    level: 1
    source: pr
    notes: Loads, starts PhysX and opens its window and OpenGL context, then crashes reading a display-mode list.
  - date: 2026-11-18
    bridge32: "18845a55"
    pr: 10
    guest: i386
    app_version: "1.0.5"
    level: 3
    source: pr
    notes: Gets through start-up to its main menu in a window. Menu text is blank and the water renders black.
  - date: 2026-11-18
    bridge32: "3af5a2c5"
    pr: 11
    guest: i386
    level: 3
    source: pr
    notes: Reaches its menu with text, water reflections and sound, and no missing imports. Typing and play past the menu aren't tried.
    screenshots:
      - url: https://github.com/user-attachments/assets/4f844402-1fce-49cf-9bb2-431dadea4743
        caption: Main menu
---

This is the i386 slice of a fat PowerPC and i386 Carbon app. `tools/make-app.sh` carries its
`Contents/PhysX` libraries into the wrapped app.
