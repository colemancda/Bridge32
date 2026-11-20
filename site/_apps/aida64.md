---
name: AIDA64
platform: ios
kind: app
reports:
  - date: 2026-11-01
    bridge32: "9819330e"
    level: 1
    source: commit
    notes: Starts and has run for ten minutes at a time. How far it gets isn't recorded.
---

Commits that name it fixed what it ran into: guest `CFAllocator`s, Firebase Analytics' app
delegate proxy, a hidden 1x1 web view that stopped the storyboard loading, a weak
`NSPointerArray`, host threads running out after ten minutes, and its Total RAM figure, which
now reads 512 MB.
