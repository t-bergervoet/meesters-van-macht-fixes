# De Meesters van Macht – Windows 11 fixes

Makes **De Meesters van Macht** (IJsfontein, 1997, Macromedia Director 6) run on 64-bit Windows 10/11,
full screen via [Magpie](https://github.com/Blinue/Magpie).

This repo contains no game files. The Dutch CD image is on the Internet Archive:
**[Meesters van macht cd-rom](https://archive.org/details/mvmacht)** ([file list](https://archive.org/download/mvmacht)).

**English version (*Masters of the Elements*) or another language?** Use Felsqualle's patches from
[*Saving the Masters of the Elements*](https://felsqualle.com/posts/2025/10/saving-the-masters-of-the-elements-epilogue/).
This repo has only been tested on the Dutch CD.

## Usage

1. Download `MvM.bin` from the [Internet Archive](https://archive.org/download/mvmacht) (about 700 MB)
   and install [7-Zip](https://www.7-zip.org/).
2. Download this repo (Code → Download ZIP) and unzip it.
3. In that folder, open PowerShell and run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\apply-fixes.ps1 -GameDir 'C:\Games\MvM' -DiscImage 'C:\path\to\MvM.bin' -InstallMagpie
   ```

4. Start the game with **`Meesters van Macht.lnk`** in the game folder.

| Parameter | |
|---|---|
| `-GameDir` | Game folder. If it doesn't contain `MvM.exe` yet, the game is installed there from `-DiscImage` |
| `-DiscImage` | `MvM.bin` or an `.iso` of the Dutch CD. Needed on the first run. Requires 7-Zip (`-SevenZip` sets its path) |
| `-InstallMagpie` | Installs Magpie v0.12.1 (checksum-verified) with a full-screen profile for the game |
| `-SkipRegistry`, `-SkipShortcut` | Leave out the compatibility flags or the launcher shortcut |

Requires 64-bit Windows 10/11 and the built-in Windows PowerShell 5.1. No admin rights needed. Safe to
rerun. Patched files keep a `*.orig` backup.

## What it fixes

| Problem | Fix |
|---|---|
| `XLib file not found` / `Handler not defined #Putcurs` on start: `PUTCURS.DLL` is 16-bit and can't load | Pointer control via SetMouseXtra (`SMXTRA.X32`, from the same CD) |
| Drag puzzles (e.g. the electricity-room wire) can't be moved | Same fix: the game can position the pointer again |
| Menu buttons only appear on mouse-over | Removed `puppetPalette("black palette", 25)` from the intro |
| Hangs after Alt-Tab or a notification | `MvM.exe` keeps running in the background |
| Random hangs during play | Launcher runs the game on one CPU core |
| No sound effects | DirectSound Xtra kept enabled; all sound effects depend on it |
| After loading a save, drag gestures (e.g. on the train) don't work | Loading resets the stuck electricity-puzzle state |
| Small 640×480 picture | Magpie scales it to full screen (4:3) |

## Technical reference

All bytecode patches keep the code length unchanged. Each pattern occurs twice per file (live and
stale chunk), and both are patched.

**`Data\Global\scripts.cst`**

- `initCursorObject` / `exitCursorObject`: skip `openXLib`/`closeXLib` of `Putcurs.dll`.
- `moveTheCursor`: `myMouse(mSet, x, y)` → `SetMouse(x, y)`, without the `objectp(myMouse)` guard. The
  name table entries `Putcurs`/`mnew` become `SetMouse`/`mne` (same total length).
- `initElecFromFile`: after `set handvatState = getAt(theList, 3)`, adds
  `if handvatState = #turn then set handvatState = 0`. The redundant `count(theList) = 11` check is
  removed to make room. Without this, a save made with the wire puzzle unfinished makes
  `clickBackground` ignore every navigation drag.

**`Data\Intro\intro.dir`**: `startIntro` jumps over `puppetPalette("black palette", 25)`.

**`MvM.exe`**: projector header `59JP` ("PJ95", next dword = offset of the `XFIR` movie). The byte
at +12 changes from `0x14` to `0x16`; bit 1 keeps the projector running when inactive.

**Compatibility flags**: `~ HIGHDPIAWARE DWM8And16BitMitigation` under
`HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers`.

**Magpie**: `magpie-profile.json` is merged into `%LOCALAPPDATA%\Magpie\config\v4\config.json`. It
matches window class `ASIMainWndClass`, auto-scales, and crops `(screen − 640×480) / 2` on each side,
calculated from the primary display. Rerun with `-InstallMagpie` after changing resolution.

**Save files** are Lingo commands, encoded per character as `255 − c` with filler bytes ≥ 128 and a
one-byte checksum. They are run with `do` on load.

**`tools/lingo-disasm.pl`** disassembles Director 5/6 compiled Lingo:
`perl tools/lingo-disasm.pl Data/Global/scripts.cst 'moveTheCursor'`

## Credits

- **[Felsqualle](https://felsqualle.com/)**: the SetMouseXtra and `puppetPalette` fixes come from
  [*Saving the Masters of the Elements*](https://felsqualle.com/posts/2025/05/saving-the-masters-of-the-elements-part-1/)
  ([part 3](https://felsqualle.com/posts/2025/07/saving-the-masters-of-the-elements-part-3/),
  [part 4](https://felsqualle.com/posts/2025/08/saving-the-masters-of-the-elements-part-4/)).
- **Stephan Eichhorn / Scirius Development**: SetMouseXtra.
- **[Blinue](https://github.com/Blinue/Magpie)**: Magpie.
- **IJsfontein**: the game.
