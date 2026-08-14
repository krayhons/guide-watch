# Guide Watch for OnionOS (Miyoo Mini Plus)

Status: working, verified on a Miyoo Mini Plus on 2026-08-14 (guide popup and
resume across several games, full PlayStation guide download on device).

Three things this device taught us, worth carrying to the next CFW port:

1. Nothing can draw over a paused RetroArch here. The frozen game frame stays
   composited on top, so the reader ran invisibly. Quit and relaunch through
   the runtime instead (see the quick-switch note below).
2. Onion's runtime deletes `cmd_to_run.sh` after every program exits unless
   `/tmp/quick_switch` exists. Without that flag a handoff lands on MainUI.
3. The busybox awk on this device fails on bracket-expression regexes and
   returns an empty string, silently. Use shell built-ins for string work.

Two sideloadable apps:

- **Guide Watch** - in-game guide popup, ported from the Anbernic StockOS mod
  UX. Consumes the "Game Name.txt" walkthroughs that guides.retromodlab.com
  writes next to each ROM.
- **Guide Downloader** - downloads those walkthroughs right on the device
  over wifi, so you never need the computer. Same index, same archive.org
  source as the web tool.

**Controls (Guide Watch)**

- Launch a game that has a guide: one short rumble = "guide available".
- Hold L2 + R2, press Down: the game auto-saves and hands the screen to the
  guide in Onion's Ebook Reader (a few seconds).
- Press MENU: reader closes, the game relaunches and auto-loads the save
  state - you are back exactly where you were (another few seconds, with
  Onion's normal loading screen). A rumble tells you the combo is armed again.
- Reading position is remembered per guide (by the Ebook Reader itself).

This uses Onion's own quick-switch mechanism (the same thing Game List
Options uses for "restart game"). The first version tried to pause RetroArch
and draw over it; the Mini Plus display hardware keeps the frozen game frame
on top, so that path is a dead end on this device.

## Requirements

- OnionOS recent enough to have the startup-scripts folder. Check that
  `/mnt/SDCARD/.tmp_update/runtime.sh` on your card contains the word
  `startup` (any Onion 4.2+ has it). If not, update Onion first.
- **Ebook Reader** installed via Package Manager (it must exist at
  `/mnt/SDCARD/App/PixelReader/`). Already on your card.

## Install (sideload)

Copy the contents of `sd-package/` onto the SD card root, merging folders:

1. `sd-package/App/GuideWatch/` -> `SDCARD/App/GuideWatch/`
2. `sd-package/App/GuideDownload/` -> `SDCARD/App/GuideDownload/`
3. `sd-package/.tmp_update/startup/guidewatch.sh` -> `SDCARD/.tmp_update/startup/guidewatch.sh`

Reboot the device. The daemon starts automatically at every boot.
The Apps menu gets two new entries: "Guide Watch" (manual stop/start of the
daemon, not needed for normal use) and "Guide Downloader".

Log files: `SDCARD/App/GuideWatch/guidewatch.log` (recreated each boot) and
`SDCARD/App/GuideDownload/guide-download.log` (recreated each run).

## Guide Downloader

Apps -> Guide Downloader (wifi must be on). It scans every mapped folder in
`Roms/` (FC, SFC, MD, GB, GBA, PS and so on - same folder map as the web
tool), counts what is missing, then shows a console picker: download for
"All consoles" or a single console (for example just PS). B cancels. Before
downloading it tells you how many guides it will fetch and a rough time
estimate; a summary panel shows new / already-had / not-matched counts when
it finishes. ROMs that already have a `.txt` next to them are never touched,
so re-runs only fetch what is new.

Matching is the web tool's exact + subtitle matcher (identical normalize
rules and hand-fix table). The fuzzy tier is web-only, so a handful of
awkwardly named ROMs will land in the log as NOT MATCHED - grab those few
with the web tool. Expect roughly one guide per second; a full card on the
first run can take a while.

## Rebuild

```
./build.sh
```

Runs the host self-test of the parsing logic, then cross-compiles
`src/guidewatch.c` inside the same Docker toolchain image OnionOS itself is
built with (`aemiii91/miyoomini-toolchain`, runs under Rosetta on Apple
Silicon). Output: `sd-package/App/GuideWatch/guidewatch`, a static ARM binary.

## How it works

- Onion's runtime writes the launch command of the current game to
  `/mnt/SDCARD/.tmp_update/cmd_to_run.sh` (removed when the game exits). The
  daemon polls it once per second; the ROM path is the last quoted argument.
- Guide file = same folder, same base name, `.txt` extension. Works with
  `.m3u` multi-disc sets since the guide matches the m3u base name.
- Rumble = GPIO 48 (active low), same as Onion's own rumble.h.
- Button combo is read from `/dev/input/event0` with Onion's hardware key
  codes (L2 = KEY_TAB, R2 = KEY_BACKSPACE).
- On combo: SIGSTOP retroarch and keymon, then launch
  `App/PixelReader/reader "<guide>"`. The guide path is also pre-seeded into
  pixel-reader's activity store, so the guide opens directly even if the
  installed reader build ignores the argument.
- Pixel-reader exits on MENU release by design; the daemon waits for it,
  flushes stale input, then SIGCONTs keymon and retroarch.

## On-device test checklist

Setup: connect wifi. After the downloader run you will have ROMs with guides
and (likely) a few without - you need one of each for the Guide Watch tests.

Downloader first:

a. Apps -> Guide Downloader with wifi OFF. Expect a "cannot reach" panel,
   nothing downloaded.
b. Turn wifi on, run it again. Expect the console picker (All + one row per
   console with missing-guide counts). First try a single small console
   (e.g. GB) and confirm only that folder gets guides. Then run again with
   "All consoles"; the fetch panel should state the count and a time
   estimate.
c. Check `App/GuideDownload/guide-download.log`: OK lines for hits,
   NOT MATCHED lines for the rest. Spot-check 2-3 downloaded `.txt` files
   next to their ROMs: real guide text, correct game.
d. Run it a third time. Everything should land in "already had one" and
   finish much faster (no re-downloads).

Then Guide Watch:

1. Copy the folders to the SD card, reboot. Verify
   `App/GuideWatch/guidewatch.log` exists on the card and contains
   "guidewatch: started".
2. Launch the game WITH a guide. Expect one short rumble a moment after the
   game starts (log: "guide armed").
3. Hold L2 + R2, tap Down. Expect: tiny rumble blip, the game quits (brief
   black screen), then the Ebook Reader opens full screen on the guide.
4. Scroll a few pages with Up/Down or L1/R1, then press MENU. Expect:
   Onion's loading screen, the game relaunches, auto-loads the save state,
   and you are where you left off. A rumble confirms the combo is armed
   again.
   - Watch for: the game restarting from the title screen instead of where
     you were. That means auto-save did not run - check that "Auto save"
     is enabled in Onion's Tweaks (it is by default).
5. Reopen the guide with the combo. Expect it at the same position you left.
6. Press MENU briefly INSIDE the game (not in the reader). Onion's normal
   in-game menu behaviour must be unaffected.
7. Launch the game WITHOUT a guide. Expect: no rumble, combo does nothing,
   game plays normally.
8. Quit to MainUI, launch the guide game again. Rumble cue and combo must
   work again (state resets between games).
9. Apps -> Guide Watch: expect "Guide daemon stopped" panel; combo now dead
   in-game. Run it again: "Guide daemon started"; combo works after the next
   game launch.
10. Leave the console idle on MainUI for a few minutes: no rumble, no
    slowdown, battery drain normal (daemon sleeps 1s between checks).
11. Optional edge cases: a game whose ROM name contains an apostrophe or
    brackets; a multi-disc .m3u.

Known quirks (by design, report only if worse than described):

- Opening and closing the guide each take a few seconds - it is a real
  save-quit-relaunch cycle, the only reliable path on this hardware.
- Requires Onion's "Auto save" (on by default). RetroArch games only.
- Big guides (500 KB+) still take extra time to open the FIRST time -
  pixel-reader lays out the whole file. Reopening is faster (cached).
- The Down press that opens the guide also reaches the game for one frame
  before the save happens.
- If you reboot while a guide is open, the next boot lands on MainUI (not
  the game) - that's the wrapper clearing a stale handoff, by design.
