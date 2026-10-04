# De Meesters van Macht – Windows 11 fixes

Fixes for **De Meesters van Macht** (Dutch kids' game by IJsfontein, 1997, Macromedia Director 6)
so it runs on 64-bit Windows 10/11, plus full-screen scaling with [Magpie](https://github.com/Blinue/Magpie).

The game files are not in this repo. `apply-fixes.ps1` patches a copy you already have. The Dutch CD
image is on the Internet Archive as
[`mvmacht`](https://archive.org/details/mvmacht) ("Meesters van macht cd-rom").

## Credits and the English version: *Masters of the Elements*

The game was also released in English as **Masters of the Elements** (and in German, French, Italian
and Japanese). **Felsqualle** documented restoring it in the series
[*Saving the Masters of the Elements*](https://felsqualle.com/posts/2025/05/saving-the-masters-of-the-elements-part-1/),
and publishes ready-made patches for every language in the
[epilogue](https://felsqualle.com/posts/2025/10/saving-the-masters-of-the-elements-epilogue/).
**If you have the English or another non-Dutch version, use those patches.**

This repo was worked out independently on the Dutch CD and then improved using that series. Two
fixes come from it: using SetMouseXtra in place of `PUTCURS.DLL`, and removing the intro's
`puppetPalette` call. In return, this repo adds a few things the series doesn't cover: the hang on
focus loss (fix 6), the single-core launcher (fix 5), and Magpie scaling instead of switching the
screen to 640×480.

How the two differ: Felsqualle recompiled the scripts in Director 6 and ships the modified game
files. This repo patches the compiled bytecode of your own copy in place and contains no game files.

## Usage

1. Copy the `MvM` folder from the CD (or disc image) to your PC, e.g. `C:\Games\MvM`.
2. Download this repo (Code → Download ZIP) and unzip it.
3. In that folder, open PowerShell and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\apply-fixes.ps1 -GameDir 'C:\Games\MvM' -DiscImage 'C:\path\to\MvM.bin' -InstallMagpie
```

4. Start the game with **`Meesters van Macht.lnk`** in the game folder.

| Parameter | |
|---|---|
| `-GameDir` | Folder containing `MvM.exe` (any location; spaces are fine) |
| `-DiscImage` | `.bin` (raw MODE1/2352) or `.iso` of the Dutch CD. Restores files missing from the install and copies `SMXTRA.X32` (SetMouseXtra) from the CD's *Webmaster demo* folder. Needed on the first run unless `Xtras\SMXTRA.X32` is already there. Needs [7-Zip](https://www.7-zip.org/) (override its path with `-SevenZip`) |
| `-InstallMagpie` | Optional. Downloads [Magpie](https://github.com/Blinue/Magpie) v0.12.1 (checksum-verified) and adds a full-screen profile |
| `-SkipRegistry`, `-SkipShortcut` | Leave out the per-user parts (compat flags, launcher shortcut) |

**Requirements:** 64-bit (x64) Windows 10 or 11 and the built-in Windows PowerShell 5.1. No admin rights
needed: everything is per-user.

The script is safe to rerun. Every step checks whether it was already applied, checks every byte
pattern before writing, and leaves a file untouched if any pattern is missing. Patched files keep a
`*.orig` copy next to them. Running it over an install patched by an older version of this script
upgrades it.

## Problems and fixes

| # | Symptom | Cause | Fix |
|---|---------|-------|-----|
| 1 | `XLib file not found` on the first screen | Files missing from the installed copy | Restored from the CD image |
| 2 | `Script error: Handler not defined #Putcurs` | `PUTCURS.DLL` is a **16-bit** XObject; 64-bit Windows cannot load 16-bit code | Bytecode patch: move the pointer with SetMouseXtra (`SMXTRA.X32`, 32-bit, on the same CD) |
| 3 | Drag-and-drop puzzles (matchbox, pan, maze) lose vertical control | The game warps the pointer during drags, which needs a working cursor Xtra | Same as 2 |
| 4 | Menu buttons only appear on mouse-over | `puppetPalette("black palette", 25)` in the intro breaks 256-colour mapping on 32-bit colour | Bytecode patch: skip that call |
| 5 | Random hangs during play | Director 6 sound mixer is not multi-core safe | Launcher runs the game with CPU affinity 1 |
| 6 | Hangs ~15–20 s after Alt-Tab or a notification, then closes | Projector pauses itself when it loses focus and deadlocks | Set "animate in background" bit in `MvM.exe`'s projector header |
| 7 | Tiny 640×480 picture | Fixed stage size | Magpie profile: crop the black border, scale to full screen (4:3 kept) |

### Things that did *not* work

- **Disabling the DirectSound Xtra** (`DSOUND_R.X32`). It looked like the cause of a menu hang, but
  every sound effect on Windows goes through `letsHear` → `playDsSound`, which plays nothing without
  it. Music and voices still play, so the problem isn't obvious. With fixes 5 and 6 in place the
  Xtra no longer hangs.
- **`640X480` compatibility mode** (Windows switches resolution): fills the screen, but the game hangs
  as soon as it loses focus, even with fix 6. Don't use it.
- **Stubbing out `Putcurs`** without a replacement. The game runs, but the drag-and-drop puzzles
  break (fix 3).
- **Renaming `Putcurs` to a built-in** (`objectp`): `Putcurs(mNew)` is compiled as an old-style method
  call (`objcallv4` on a var ref), so the result still passed `objectp()`, and the game crashed later
  with `Property not found #offSetY`.

## Patch details

All bytecode patches keep the length of the code unchanged and jump over code that is no longer
used. Director files keep a stale copy of older chunks, so each pattern occurs twice and both copies
are patched.

### `Data\Global\scripts.cst` – Cursor Script

Lingo equivalent after patching (same as Felsqualle's recompiled version):

```lingo
on initCursorObject
  ...
  if platform = #windows then
    -- no openXLib / Putcurs(mNew): SetMouseXtra autoloads from Xtras\
  else ...
end

on moveTheCursor x, y
  -- no "if not objectp(myMouse) then return"
  if platform = #windows then
    set offSetX = the stageLeft + ...
    set offSetY = the stageTop + ...
    SetMouse(integer(x + offSetX), integer(y + offSetY))
  else ...
end
```

| Where | Before | After |
|---|---|---|
| Name table (shared by the cast) | `07 "Putcurs"`, `04 "mnew"` | `08 "SetMouse"`, `03 "mne"` (same total length; both names were only used by `initCursorObject`) |
| `initCursorObject` +29 | `89 0154` getglobal objectPath (start of `openXLib`) | `93 0033` jmp to `ret` |
| `exitCursorObject` +29 | `89 0154` (start of `closeXLib`) | `93 0019` jmp to `ret` |
| `moveTheCursor` +0 | `89 0151` getglobal myMouse (the `objectp` guard) | `93 0010` jmp +16 |
| `moveTheCursor` +60 (30 bytes) | `pushsymb #mSet`, x, y, `pusharglistnoret 3`, `pushvarref myMouse`, `objcallv4` | x, y, `pusharglistnoret 2`, `extcall SetMouse`, `jmp +5`, 2 filler bytes |

### `Data\Intro\intro.dir` – `startIntro`

```
before  44 20  pushcons "black palette"     after  93 0008  jmp +8
        41 19  pushint 25                          00 x5    (never executed)
        42 02  pusharglistnoret 2
        57 43  extcall puppetPalette
```

### `MvM.exe` – projector header

The Director 6 Windows projector has a little-endian `PJ95` header (`59JP` in the file) whose next
dword points to the embedded `XFIR` movie. Layout as observed in this exe:

| Offset | Value | Meaning |
|-------:|-------|---------|
| +0 | `59JP` | magic |
| +4 | `0x0016D737` | offset of embedded movie |
| +8 | `0x22` | flags (unknown) |
| +12 | `0x14` → **`0x16`** | flags; bit 1 = keep running when inactive |
| +20 | `640, 480` | stage size |

Bit 1 was found by trying each unset bit and checking whether the game survived 25–45 s in the
background. Only this bit passed every run.

### Compatibility flags

`HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers` →
`~ HIGHDPIAWARE DWM8And16BitMitigation`. `HIGHDPIAWARE` stops Windows stretching the window itself,
so Magpie gets a sharp 640×480 source. It also means `SetMouse` coordinates are in physical pixels,
which matches what the game calculates.

### Magpie

`magpie-profile.json` is merged into `%LOCALAPPDATA%\Magpie\config\v4\config.json`. The profile
matches window class `ASIMainWndClass` and auto-scales. The projector centres the 640×480 stage on a
full-screen window on the primary display. The script reads that display's resolution in physical
pixels and sets the crop to `(width − 640) / 2` and `(height − 480) / 2` (960/560 px at 2560×1600).
If you change resolution or primary monitor later, rerun with `-InstallMagpie`. The script also
enables `allowScalingMaximized`, because the projector window covers the whole screen, and turns off
Magpie's update check.

## Tools

`tools/lingo-disasm.pl` is a small disassembler for Director 5/6 compiled Lingo in big-endian `RIFX`
files. It was used to find the patches above.

```sh
perl tools/lingo-disasm.pl Data/Global/scripts.cst 'CursorObject|moveTheCursor'
```
