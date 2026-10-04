# De Meesters van Macht – Windows 11 fixes

Fixes for **De Meesters van Macht** (Dutch kids' game, 1997, Macromedia Director 6) so it runs on
64-bit Windows 10/11, plus full-screen scaling with [Magpie](https://github.com/Blinue/Magpie).

The game files are not in this repo. `apply-fixes.ps1` patches a copy you already have. The Dutch CD
image is on the Internet Archive as
[`mvmacht`](https://archive.org/details/mvmacht) ("Meesters van macht cd-rom").

## English version: *Masters of the Elements*

The game was also released in English as **Masters of the Elements**. It's the same Director 6 game,
so it very likely has the same problems: the 16-bit `PUTCURS.DLL`, the DirectSound Xtra, and the hang
on focus loss.

**These fixes have only been tested on the Dutch CD.** The script looks for the exact byte patterns
it patches rather than fixed offsets, and stops without changing anything if a pattern isn't found.
So it's safe to try on the English version, but it may refuse. If you have the English version and
it works (or doesn't), please open an issue.

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
| `-DiscImage` | Optional. `.bin` (raw MODE1/2352) or `.iso`. Restores files missing from the install, including `Xtras\PUTCURS.DLL`, which the game needs even though it can't use it. Needs [7-Zip](https://www.7-zip.org/) (override its path with `-SevenZip`) |
| `-InstallMagpie` | Optional. Downloads [Magpie](https://github.com/Blinue/Magpie) v0.12.1 (checksum-verified) and adds a full-screen profile |
| `-SkipRegistry`, `-SkipShortcut` | Leave out the per-user parts (compat flags, launcher shortcut) |

**Requirements:** 64-bit (x64) Windows 10 or 11 and the built-in Windows PowerShell 5.1. No admin rights
needed: everything is per-user.

The script is safe to rerun. Every step checks whether it was already applied, and patched files keep a
`*.orig` copy next to them.

## Problems and fixes

| # | Symptom | Cause | Fix |
|---|---------|-------|-----|
| 1 | `XLib file not found` on the first screen | `Xtras\PUTCURS.DLL` and 11 sound files were missing from the installed copy | Restored from the CD image |
| 2 | `Script error: Handler not defined #Putcurs` | `PUTCURS.DLL` is a **16-bit** XObject; 64-bit Windows cannot load 16-bit code | Patched `scripts.cst` bytecode so `myMouse` becomes 0 (see below) |
| 3 | Game hangs on the first menu click (0% CPU) | 1996 DirectSound Xtra `DSOUND_R.X32` deadlocks | Moved to `Xtras (disabled)`; the game falls back to Director's built-in sound |
| 4 | Random hangs during play | Director 6 sound mixer is not multi-core safe | Launcher runs the game with CPU affinity 1 |
| 5 | Hangs ~15–20 s after Alt-Tab or a notification, then closes | Projector pauses itself when it loses focus and deadlocks | Set "animate in background" bit in `MvM.exe`'s projector header |
| 6 | Tiny 640×480 picture | Fixed stage size | Magpie profile: crop the black border, scale to full screen (4:3 kept) |

### Things that did *not* work

- **`640X480` compatibility mode** (Windows switches resolution): fills the screen, but the game hangs
  as soon as it loses focus, even with fix 5. Don't use it.
- **Renaming `Putcurs` in the Lingo name table** to a built-in (`objectp`): `Putcurs(mNew)` is compiled
  as an old-style method call (`objcallv4` on a var ref), so `objectp(mNew)` still produced something
  `objectp()` accepts, and the game crashed later with `Property not found #offSetY`.

## Patch details

### `Data\Global\scripts.cst` – `initCursorObject`

```
before  85 0156   pushsymb   #mnew
        43 01     pusharglist 1
        86 0155   pushvarref Putcurs
        58 01     objcallv4
        8f 0151   setglobal  myMouse
after   03        push0
        93 0009   jmp +9          ; to setglobal
        00 x6     (never executed)
        8f 0151   setglobal  myMouse
```

`moveTheCursor` already starts with `if not objectp(myMouse) then return`, so the game simply never
moves the mouse pointer itself. That is all `PUTCURS.DLL` did. The pattern occurs twice in the file
(the second copy is stale) and both are patched.

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
so Magpie gets a sharp 640×480 source.

### Magpie

`magpie-profile.json` is merged into `%LOCALAPPDATA%\Magpie\config\v4\config.json`. The profile
matches window class `ASIMainWndClass` and auto-scales. The projector centres the 640×480 stage on a
full-screen window on the primary display. The script reads that display's resolution in physical
pixels and sets the crop to `(width − 640) / 2` and `(height − 480) / 2` (960/560 px at 2560×1600).
If you change resolution or primary monitor later, rerun with `-InstallMagpie`. The script also enables `allowScalingMaximized`,
because the projector window covers the whole screen, and turns off Magpie's update check.

## Tools

`tools/lingo-disasm.pl` is a small disassembler for Director 5/6 compiled Lingo in big-endian `RIFX`
files. It was used to find the patches above.

```sh
perl tools/lingo-disasm.pl Data/Global/scripts.cst 'CursorObject|moveTheCursor'
```
