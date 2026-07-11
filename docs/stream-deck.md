# Stream Deck integration (design notes)

Shepherd drives an Elgato Stream Deck directly over USB HID from Swift (`Sources/StreamDeck.swift`),
reusing the HUD's model and ordering so the two views never drift. No Python, no external deps.

## Why native Swift (not the Python prototype)

An earlier prototype (`shepherd-deck`, python-elgato-streamdeck) worked but duplicated the sort
order, status meanings and colours in Python — a drift hazard — and needed a venv + a separate
process. Folding it into `Shepherd.app` lets the deck reuse `AgentRow` / `style(for:)` /
`groupByRepo` / the status-change ordering / `Cat` colours verbatim, and adds an in-app ⚙ toggle.

## Device protocol (Stream Deck MK.2 / Original V2, "Gen2")

Ported from python-elgato-streamdeck's `StreamDeckOriginalV2`. Constants live in `StreamDeck.swift`.

- USB VID `0x0fd9` (Elgato); PIDs `0x0080` (MK.2), `0x006d` (Original V2), `0x00a5`, `0x00b9`
- 15 keys (5×3). Key image: **72×72 JPEG, flipped on both axes** (= rotated 180°). We draw upright
  into a 180°-rotated CGContext so the device flips it back to upright (`encodeKeyImage`).
- **Key image** — output reports, report id `0x02`. Header (8 bytes):
  `[0x02, 0x07, key, isLast, len_lo, len_hi, page_lo, page_hi]` + payload, padded to 1024 bytes.
- **Reset** — feature report `[0x03, 0x02]` (32 bytes). **Brightness** — feature `[0x03, 0x08, pct]`.
- **Key presses** — input reports; key states start at **offset 4** (`[reportID, 0x00, count, 0x00, s0, s1, …]`).

IOKit specifics: enumerate with `IOServiceGetMatchingServices` (VID+PID), open one device with
`IOHIDDeviceOpen`, `IOHIDDeviceSetReport` for output/feature (report buffer *includes* the report id
as byte 0, matching hidapi), `IOHIDDeviceRegisterInputReportCallback` scheduled on the main run loop
for presses. Serial is read via `kIOHIDSerialNumberKey`.

## App wiring (`main.swift`)

- ⚙ header button → menu → **Use Stream Deck** toggles `enableDeck()` / `disableDeck()`; persisted in
  the `deckEnabled` default and restored on launch.
- `renderDeck()` runs on each 5s refresh: flatten `groupByRepo(lastRows)` → keys 0..13 = agents,
  key 14 = attach. Server-down shows a red key 0.
- A 0.7s `blinkTimer` re-renders only the blocked keys (peach ⇄ base) so "needs input" stands out
  without redrawing the whole board.
- Key press → `handleDeckKey` → the HUD's existing `handleClick(paneId)` (attach key → `handleClick("")`).
- The official Elgato app can't share the device; `enableDeck()` refuses if `pgrep -x "Stream Deck"`
  matches, and drops the deck with a header note if a write fails (unplug).

## Config

- `deckEnabled` (bool) — remembered toggle state.
- `deckSerial` (string) — pin a specific device when several are connected (default: first).

## Hardware-verify points

Device I/O can't be validated without the physical deck. On first real-device test, check:
1. Key text is upright (if upside-down, the 180° flip in `encodeKeyImage` is the lever).
2. Pressing a key jumps the right agent (if off-by-one/no-response, the input **offset 4** in
   `handleInput` is the lever).
