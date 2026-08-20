# Syncopation — Releases

What each version repaired, what it added, and how the two editions compare
at that version. Newest first. Codenames are project names; the product is
Syncopation. The running bulletin board, with an RSS feed, is
[synco.uno/dispatches](https://synco.uno/dispatches).

Numbering: `#.0.x` is a patch — repairs, no new ideas, and it keeps the
family codename. `#.#` is a version, free to everyone who owns the major it
belongs to. `#.0` is a major release, the only kind anyone is asked to pay
for again.

---

## 1.1 · Podification — August 20, 2026

| Edition | Build | Status |
|---|:---:|---|
| **Pro 1.1** | 4 | **Mac App Store — released August 20, 2026.** The first Pro release to reach the public; 1.0 and the 1.0.1 repairs ship inside it. |
| **CE 1.1** | 3 | **GitHub — released August 20, 2026.** |

### Added

- **Synco-pod** *(both)* — Music / Audiobooks, one control. Audiobooks land
  on the device as `.m4b` — the form its accounting and bookmarking key on —
  so they file under the Audiobooks menu, resume where you stopped, and stay
  out of shuffle. `.m4b` sources are audiobooks whichever way the control is
  set. Podcast filing is being developed: the Podcasts menu wants episode
  metadata the writer cannot produce yet. DRM-free files only: Apple Books
  and Audible purchases are copy-protected and cannot make the trip.
- **Appearance** *(both)* — follow the system, or pin the window light
  or dark. The dark theme is built on the synco.uno palette.
- **Liquid Glass and window transparency, each switchable off** *(Pro)* —
  translucency is lovely until it isn't, and nobody should have to read text
  through their own wallpaper.
- **A sound when a sync finishes** *(both)* — whatever alert tone you
  already chose in System Settings, at your volume. It sounds for a failure
  too.
- **One control language** *(both)* — selector tracks and action
  buttons share a height, a type size, and the same glass; the active segment
  is a real button that travels between positions rather than paint that
  jumps. Both meters are drawn by hand so they take the app's tint instead of
  the system accent.

### Repaired

- **Match Default Source removes items, not songs** *(Pro)* — the word
  stopped being true the moment episodes and audiobooks could be synced.
- **Pro also carries every 1.0.1 repair below.** They never shipped on their
  own number.

### Pro vs CE at 1.1

| | **Pro** | **CE** |
|---|:---:|:---:|
| Synco-pod — audiobooks filed as such (podcasts in development) | ✓ | ✓ |
| Appearance — system, light, or dark | ✓ | ✓ |
| Liquid Glass and window transparency switchable off | ✓ | n/a — already flat |
| A sound when a sync finishes | ✓ | ✓ |
| One control language | ✓ | ✓ |
| Match Default Source removes items, not just songs | ✓ | — |

---

## 1.0.1 · Origen — repairs

| Edition | Build | Status |
|---|:---:|---|
| **Pro 1.0.1** | 3 | Rolled up into 1.1 — never shipped on its own number. |
| **CE 1.0.1** | 2 | **GitHub — released August 16, 2026.** |

Point releases keep the family name. Repairs cross editions when they're
ready; features make the trip on their own schedule.

### Repaired

- **Conversion runs ahead of the copy.** *Issue:* the CPU and the USB cable
  took turns — a track was converted, then copied, then the next one
  started — so a large first sync ran at the sum of both. *Repair:* a few
  converted tracks are kept ready ahead of the transfer. Roughly half the
  time on machines where conversion was the bottleneck.
- **The Mac stays awake mid-sync.** *Issue:* idle sleep cut USB power and
  took the iPod with it, politely, halfway through. *Repair:* a power
  assertion is held for as long as a sync runs. The display may sleep; the
  sync may not.
- **Space math got honest about hi-res.** *Issue:* converted tracks were
  priced at their source size, so a 24-bit album that would shrink on
  conversion was refused even though it fit. *Repair:* the free-space check
  estimates what a track will weigh on the device, capped at the source size.

### Added

Nothing. Repairs only.

### Pro vs CE at 1.0.1

| | **Pro** | **CE** |
|---|:---:|:---:|
| Conversion pipelined ahead of the copy | ✓ | ✓ |
| The Mac stays awake while a sync runs | ✓ | ✓ |
| Space check prices hi-res tracks at their converted size | ✓ | ✓ |

---

## 1.0 · Origen

| Edition | Build | Status |
|---|:---:|---|
| **Pro 1.0** | 2 | Submitted to App Review August 11, 2026; rolled up into 1.1. |
| **CE 1.0** | 1 | **GitHub — released August 8, 2026.** Codename assigned in retrospect. |

### Added

The first release. Music onto iPods and MP3 players, books onto e-readers,
anything at all onto folders, cards, and drives. FLAC converts to Apple
Lossless on the way to an iPod; the iPod's own database is written natively;
nothing ever touches a server because there is no server.

### Known issues at 1.0

All three repaired in 1.0.1: conversion and copy took turns; idle sleep
could interrupt a long sync; hi-res albums that would fit after conversion
were refused on principle.

### Not supported

- Artwork on pre-2007 iPods — older thumbnail formats, not yet verified
  against hardware; music syncs normally, artwork is skipped.
- iPod shuffle — detected and refused with a clear message. Not planned.
- hash72 / hashAB devices (nano 5G and later, iPod touch, iPhone) — refused.

### Pro vs CE at 1.0

| | **Pro** | **CE** |
|---|:---:|:---:|
| Four Synco-modes — Music, ePUB/PDF, All Files, iPod | ✓ | ✓ |
| Native iPod database engine — hash58 checksums, tracks play on eject | ✓ | ✓ |
| FLAC → Apple Lossless, 16-bit, in-process | ✓ | ✓ |
| iPod identification | Exact model — "iPod classic (7th gen)" | Family only — "iPod classic" |
| Album artwork on the iPod | ✓ | — |
| Skips tracks already on the device | By tags — even ones another app put there | By file |
| Interrupted sync | Checkpointed — carries on where it stopped | Stops cleanly — tidies up on the next run |
| Reclaims stray files other software left behind | ✓ | — |
| Two-way sync for folders and SD cards | ✓ | — |
| Match Default Source — device mirrors the folder, deletions included | ✓ | — |
| Preview, Erase, Eject, free-space check | ✓ | ✓ |
| Debug drawer — device facts and the per-file log | ✓ | ✓ |
| Interface | Liquid Glass on macOS 26, native controls on 13–15 | Flat, native |
| Distribution | Mac App Store — sandboxed, notarized, reviewed | GitHub — clone it, build it |
| Price | $19.99 once; $24.99 from January 1, 2027 | Free, GPL v3 |

---

Copyright © 2026 Eddie Hajek. iPod is a trademark of Apple Inc.; Syncopation
is not affiliated with or endorsed by Apple.
