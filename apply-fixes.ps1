<#
.SYNOPSIS
    Makes "De Meesters van Macht" (1997, Macromedia Director 6) run on 64-bit Windows 10/11.

.DESCRIPTION
    Applies every fix from this repo to an installed copy of the game. Safe to run more than once:
    each step checks whether it has already been applied. Originals are kept as *.orig.

      1. Restore files missing from the install (sound files) and copy SMXTRA.X32 from the CD image.
      2. Patch Data\Global\scripts.cst to move the mouse pointer with SetMouseXtra instead of the
         16-bit Putcurs XObject, and Data\Intro\intro.dir so the menu appears without mouse-over.
         Saved games with the electricity puzzle unfinished no longer break navigation on load.
      3. Patch MvM.exe's projector header so the game keeps running when it loses focus.
      4. Make sure the DirectSound Xtra is enabled (all sound effects depend on it).
      5. Set compatibility flags (HIGHDPIAWARE, DWM8And16BitMitigation).
      6. Create a "Meesters van Macht" launcher shortcut (single CPU core, starts Magpie).
      7. Optionally install Magpie and add a full-screen scaling profile for the game.

.EXAMPLE
    .\apply-fixes.ps1 -GameDir 'C:\Games\MvM' -DiscImage 'C:\Games\MvM\Disc image (Internet Archive)\MvM.bin' -InstallMagpie
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $GameDir,
    [string] $DiscImage,
    [switch] $InstallMagpie,
    [switch] $SkipRegistry,
    [switch] $SkipShortcut,
    [string] $SevenZip = 'C:\Program Files\7-Zip\7z.exe'
)

$ErrorActionPreference = 'Stop'
# With -DiscImage the game folder may be new or empty: step 1 then installs the game from the CD image.
if ($DiscImage -and -not (Test-Path $GameDir)) { New-Item -ItemType Directory $GameDir | Out-Null }
$GameDir = (Resolve-Path $GameDir).Path
$exe = Join-Path $GameDir 'MvM.exe'
if (-not (Test-Path $exe) -and -not $DiscImage) { throw "MvM.exe not found in $GameDir (pass -DiscImage to install it from the CD image)" }

$MagpieVersion = 'v0.12.1'
$MagpieSha256  = '8bc8bc233438f546b7996b00b21d7376f4f7d3d8a4940e6a8800babd2225b2de'
$MagpieDir     = Join-Path $env:LOCALAPPDATA 'Programs\Magpie'

function Write-Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }

function Backup-Once($path) {
    if (-not (Test-Path "$path.orig")) { Copy-Item -LiteralPath $path "$path.orig" }
}

function Find-Bytes([byte[]] $haystack, [byte[]] $needle) {
    $hits = @()
    for ($i = 0; $i -le $haystack.Length - $needle.Length; $i++) {
        if ($haystack[$i] -ne $needle[0]) { continue }
        $match = $true
        for ($j = 1; $j -lt $needle.Length; $j++) { if ($haystack[$i + $j] -ne $needle[$j]) { $match = $false; break } }
        if ($match) { $hits += $i }
    }
    return $hits
}

function Get-PrimaryScreenSize {
    # Physical pixels of the primary display's current mode, independent of DPI scaling and of
    # how many GPUs/monitors there are. The projector runs full screen on the primary display.
    Add-Type -Namespace MvmFixes -Name Display -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
}
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
public static int[] PrimarySize() {
    var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, -1, ref dm)) return null;   // -1 = ENUM_CURRENT_SETTINGS
    return new[] { dm.dmPelsWidth, dm.dmPelsHeight };
}
'@ -ErrorAction SilentlyContinue
    $size = [MvmFixes.Display]::PrimarySize()
    if (-not $size) { throw 'Could not read the primary display mode.' }
    [pscustomobject]@{ Width = $size[0]; Height = $size[1] }
}

function ConvertFrom-Hex([string] $hex) {
    $hex = $hex -replace '\s', ''
    [byte[]] ($hex -split '(..)' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) })
}

function Invoke-BytePatch([string] $path, [object[]] $patches) {
    # Each patch is @{ Name; From; To } (hex). Every pattern is checked before anything is written,
    # so a file is either fully patched or left untouched. A pattern occurring more than once is
    # patched everywhere (Director files keep stale copies of old chunks).
    $bytes = [IO.File]::ReadAllBytes($path)
    $plan = foreach ($p in $patches) {
        $from = ConvertFrom-Hex $p.From; $to = ConvertFrom-Hex $p.To
        if ($from.Length -ne $to.Length) { throw "$($p.Name): patch changes length" }
        $hits = @(Find-Bytes $bytes $from)
        if ($hits.Count -eq 0) {
            if (@(Find-Bytes $bytes $to).Count -gt 0) { Write-Host "  $($p.Name): already patched."; continue }
            throw "$(Split-Path -Leaf $path): '$($p.Name)' not found - unknown version of the game? Nothing was changed."
        }
        @{ Name = $p.Name; To = $to; Hits = $hits }
    }
    if (-not $plan) { return }
    Backup-Once $path
    foreach ($p in $plan) {
        foreach ($h in $p.Hits) { [Array]::Copy($p.To, 0, $bytes, $h, $p.To.Length) }
        Write-Host "  $($p.Name): patched at offset(s) $($p.Hits -join ', ')."
    }
    [IO.File]::WriteAllBytes($path, $bytes)
}

# ---------------------------------------------------------------------------------------------
Write-Step '1. Restore missing files from the CD image'
if (-not $DiscImage) {
    Write-Host 'No -DiscImage given; skipping. (Xtras\SMXTRA.X32 must already be present.)'
} else {
    if (-not (Test-Path $SevenZip)) { throw "7-Zip not found at $SevenZip" }
    $tmp = Join-Path $env:TEMP "mvm-fixes-$PID"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        $iso = Join-Path $tmp 'MvM.iso'
        if ($DiscImage -match '\.bin$') {
            # Raw MODE1/2352 sectors -> plain 2048-byte ISO sectors
            $src = [IO.File]::OpenRead($DiscImage); $dst = [IO.File]::Create($iso)
            $buf = New-Object byte[] (2352 * 512)
            while (($n = $src.Read($buf, 0, $buf.Length)) -gt 0) {
                for ($o = 0; $o + 2352 -le $n; $o += 2352) { $dst.Write($buf, $o + 16, 2048) }
            }
            $src.Close(); $dst.Close()
        } else {
            $iso = $DiscImage
        }
        & $SevenZip x $iso 'MvM\MvM.exe' 'MvM\Data\*' 'MvM\Xtras\*' 'Webmaster demo\Xtras\Windows\SMXtra.X32' "-o$tmp\x" -y | Out-Null
        $root = Join-Path $tmp 'x\MvM'
        $restored = 0
        Get-ChildItem -Recurse -File $root | Where-Object Name -ne 'PUTCURS.DLL' | ForEach-Object {
            $rel = $_.FullName.Substring($root.Length + 1)
            $target = Join-Path $GameDir $rel
            $disabled = Join-Path $GameDir ('Xtras (disabled)\' + $_.Name)
            if (-not (Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $disabled)) {
                New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
                Copy-Item -LiteralPath $_.FullName $target
                Write-Host "  restored $rel"
                $restored++
            }
        }
        # SetMouseXtra ships on the same CD (in the Webmaster demo); it replaces PUTCURS.DLL.
        $smx = Join-Path $tmp 'x\Webmaster demo\Xtras\Windows\SMXtra.X32'
        $smxTarget = Join-Path $GameDir 'Xtras\SMXTRA.X32'
        if ((Test-Path $smx) -and -not (Test-Path $smxTarget)) {
            New-Item -ItemType Directory -Force (Split-Path $smxTarget) | Out-Null
            Copy-Item $smx $smxTarget
            Write-Host '  restored Xtras\SMXTRA.X32 (from Webmaster demo)'
            $restored++
        }
        Write-Host "  $restored file(s) restored."
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}
if (-not (Test-Path $exe)) { throw "MvM.exe not found in $GameDir, and the CD image did not contain it." }

# ---------------------------------------------------------------------------------------------
Write-Step '2. Patch scripts.cst: replace the 16-bit Putcurs XObject with SetMouseXtra'
# The game warps the mouse pointer during drag-and-drop puzzles (matchbox, pan, maze). The original
# 16-bit PUTCURS.DLL cannot load on 64-bit Windows; SetMouseXtra (SMXTRA.X32, 32-bit, same CD) can.
# Approach from Felsqualle, "Saving the Masters of the Elements" part 3:
# https://felsqualle.com/posts/2025/07/saving-the-masters-of-the-elements-part-3/
# Equivalent Lingo after patching:
#   on initCursorObject  -- Windows branch: no openXLib, no Putcurs(mNew)
#   on exitCursorObject  -- Windows branch: no closeXLib
#   on moveTheCursor x,y -- no objectp(myMouse) guard; SetMouse(integer(x+offSetX), integer(y+offSetY))
if (-not (Test-Path (Join-Path $GameDir 'Xtras\SMXTRA.X32'))) {
    throw 'Xtras\SMXTRA.X32 is missing. Rerun with -DiscImage (it is copied from the CD''s Webmaster demo).'
}
$cst = Join-Path $GameDir 'Data\Global\scripts.cst'
$cstPatches = @(
    # Undo the previous version of this fix ("set myMouse = 0") so the handler matches again.
    @{ Name = 'undo old Putcurs stub'
       From = '039300090000000000008f0151'
       To   = '850156430186015558018f0151' }
)
$bytes = [IO.File]::ReadAllBytes($cst)
if (@(Find-Bytes $bytes (ConvertFrom-Hex $cstPatches[0].From)).Count -gt 0) { Invoke-BytePatch $cst $cstPatches }
Invoke-BytePatch $cst @(
    # Name table (shared by all scripts in the cast): "Putcurs" -> "SetMouse", "mnew" -> "mne".
    # Same total length. Both names are only used by initCursorObject.
    @{ Name = 'name table'
       From = '0a 6f626a65637450617468 07 50757463757273 04 6d6e6577 09 4d6f76654d6f757365'
       To   = '0a 6f626a65637450617468 08 5365744d6f757365 03 6d6e65 09 4d6f76654d6f757365' }
    # initCursorObject: offset 29 "getglobal objectPath" (start of openXLib) -> jmp +51 to ret.
    @{ Name = 'initCursorObject'
       From = '890151430197015095000d8501524201860151580149c345c40f95001e 890154 44000a4201970153850156430186015558018f015193001b89015444080a4201970153850156430186015758018f015101'
       To   = '890151430197015095000d8501524201860151580149c345c40f95001e 930033 44000a4201970153850156430186015558018f015193001b89015444080a4201970153850156430186015758018f015101' }
    # exitCursorObject: offset 29 (start of closeXLib) -> jmp +25 to ret.
    @{ Name = 'exitCursorObject'
       From = '890151430197015095000d8501524201860151580149c345c40f950011 890154 44100a420197015893000e89015444180a420197015801'
       To   = '890151430197015095000d8501524201860151580149c345c40f950011 930019 44100a420197015893000e89015444180a420197015801' }
    # moveTheCursor: offset 0 guard -> jmp +16; offset 60..89 "myMouse(mSet, a, b)" ->
    #   a | b | pusharglistnoret 2 | extcall SetMouse (name 0x155) | jmp +5 | 2 filler bytes
    @{ Name = 'moveTheCursor'
       From = '890151 4301970150149500074200573549c345c40f9500484300a6015a41049f015b44200f04058f01594300a6015d412a9f015b44280f04058f015c 85015e 4b0089015905430157974b0889015c0543015797 4203 860151 5801 93001985015f4b00430157974b08430157974203860151580143006689520001'
       To   = '930010 4301970150149500074200573549c345c40f9500484300a6015a41049f015b44200f04058f01594300a6015d412a9f015b44280f04058f015c 4b0089015905430157974b0889015c0543015797 4202 970155 930005 0000 93001985015f4b00430157974b08430157974203860151580143006689520001' }
)

# ---------------------------------------------------------------------------------------------
Write-Step '2b. Patch intro.dir: remove the palette fade that hides the menu'
# startIntro calls puppetPalette("black palette", 25). On 32-bit colour Windows this breaks the
# 256-colour palette mapping and menu buttons only appear on mouse-over. Found by Felsqualle:
# https://felsqualle.com/posts/2025/08/saving-the-masters-of-the-elements-part-4/
#   44 20 pushcons | 41 19 pushint 25 | 42 02 pusharglistnoret 2 | 57 43 extcall puppetPalette
# -> 93 0008 jmp +8 | 5 filler bytes. The trailing "42 00 57 44" (updateStage) anchors the match.
Invoke-BytePatch (Join-Path $GameDir 'Data\Intro\intro.dir') @(
    @{ Name = 'startIntro puppetPalette'
       From = '4420411942025743 42005744'
       To   = '9300080000000000 42005744' }
)

# ---------------------------------------------------------------------------------------------
Write-Step '2c. Patch scripts.cst: ignore a "handle held" state in saved games'
# Saving while the electricity-room wire puzzle is unfinished stores handvatState = #turn.
# clickBackground starts with "if handvatState = #turn or #move then exit", so after loading such a
# save every navigation drag in every room is ignored. initElecFromFile now resets #turn to 0;
# initHandvat turns that into #lamp (handle at the start) when the room is entered.
# (#move only exists while the mouse button is held inside the puzzle, so it cannot be saved.)
# Room for the check comes from dropping the redundant "count(theList) = 11" test (listP stays):
#   +10  count check (12 bytes) + slots 1-3 (32 bytes)
#   ->   slots 1-3 | 49 4f getglobal handvatState | 45 a0 pushsymb #turn | 0f eq
#        95 0007 jmpifz +7 | 03 push0 | 8f 004f setglobal handvatState
Invoke-BytePatch $cst @(
    @{ Name = 'initElecFromFile'
       From = '4b00430197017c950086 4b004301578c410b0f95007a 4b004101430257598f0205 4b004102430257598f0206 4b004103430257594f4f'
       To   = '4b00430197017c950086 4b004101430257598f0205 4b004102430257598f0206 4b004103430257594f4f 494f45a00f950007038f004f' }
)

# ---------------------------------------------------------------------------------------------
Write-Step '3. Patch MvM.exe: keep running in the background'
# The Director 6 Windows projector stores its options in a little-endian "PJ95" header
# (bytes "59JP"), whose next dword is the offset of the embedded XFIR movie.
# Header byte +12 is 0x14 on the CD; setting bit 1 (0x16) stops the projector from pausing when
# it loses focus. With it cleared the game hangs ~15-20 s after Alt-Tab or a notification.
$bytes = [IO.File]::ReadAllBytes($exe)
$hdr = $null
foreach ($p in (Find-Bytes $bytes ([Text.Encoding]::ASCII.GetBytes('59JP')))) {
    $rifx = [BitConverter]::ToUInt32($bytes, $p + 4)
    if ($rifx -lt $bytes.Length - 4 -and [Text.Encoding]::ASCII.GetString($bytes, $rifx, 4) -eq 'XFIR') { $hdr = $p; break }
}
if ($null -eq $hdr) { throw 'MvM.exe: projector header not found.' }
$flagPos = $hdr + 12
if ($bytes[$flagPos] -band 0x02) {
    Write-Host ('  already patched (flags 0x{0:X2}).' -f $bytes[$flagPos])
} else {
    Backup-Once $exe
    $old = $bytes[$flagPos]
    $bytes[$flagPos] = $bytes[$flagPos] -bor 0x02
    [IO.File]::WriteAllBytes($exe, $bytes)
    Write-Host ('  flags at 0x{0:X} changed 0x{1:X2} -> 0x{2:X2}.' -f $flagPos, $old, $bytes[$flagPos])
}

# ---------------------------------------------------------------------------------------------
Write-Step '4. Keep the DirectSound Xtra enabled'
# On Windows, every sound effect goes through letsHear -> playDsSound, which only plays when
# DSOUND_R.X32 is loaded; without it effects are silently dropped (music and voices still play).
# An earlier version of this script disabled it because the menu hung on the first click; that
# hang does not occur with the single-core launcher and the background flag from step 3.
$xtra = Join-Path $GameDir 'Xtras\DSOUND_R.X32'
$disabled = Join-Path $GameDir 'Xtras (disabled)\DSOUND_R.X32'
if (Test-Path $xtra) {
    Write-Host '  enabled.'
} elseif (Test-Path $disabled) {
    Move-Item $disabled $xtra
    Remove-Item (Split-Path $disabled) -ErrorAction SilentlyContinue   # only if now empty
    Write-Host '  re-enabled (moved back from "Xtras (disabled)").'
} else {
    Write-Warning 'Xtras\DSOUND_R.X32 is missing: sound effects will be silent. Rerun with -DiscImage.'
}

# ---------------------------------------------------------------------------------------------
Write-Step '5. Compatibility flags'
if ($SkipRegistry) {
    Write-Host '  skipped.'
} else {
    # HIGHDPIAWARE: no Windows bitmap stretching, so Magpie gets a sharp 640x480 source.
    # Deliberately NOT 640X480: switching display mode makes the game hang on focus loss.
    $layers = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    if (-not (Test-Path $layers)) { New-Item -Force $layers | Out-Null }
    Set-ItemProperty $layers -Name $exe -Value '~ HIGHDPIAWARE DWM8And16BitMitigation'
    Write-Host "  set for $exe"
}

# ---------------------------------------------------------------------------------------------
Write-Step '6. Launcher shortcut'
if ($SkipShortcut) {
    Write-Host '  skipped.'
} else {
    # Single core: Director 6's sound mixer is not safe on multi-core CPUs.
    $lnk = Join-Path $GameDir 'Meesters van Macht.lnk'
    $magpieExe = Join-Path $MagpieDir 'Magpie.exe'
    $lnkArgs = if ($InstallMagpie -or (Test-Path $magpieExe)) {
        "/c start `"`" `"$magpieExe`" -t & start `"`" /affinity 1 `"MvM.exe`""
    } else {
        '/c start "" /affinity 1 "MvM.exe"'
    }
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $s.TargetPath = "$env:WINDIR\System32\cmd.exe"
    $s.Arguments = $lnkArgs
    $s.WorkingDirectory = $GameDir
    $s.IconLocation = "$exe,0"
    $s.WindowStyle = 7
    $s.Description = 'Meesters van Macht'
    $s.Save()
    Write-Host "  created $lnk"
}

# ---------------------------------------------------------------------------------------------
Write-Step '7. Magpie full-screen scaling'
if (-not $InstallMagpie) {
    Write-Host '  skipped (use -InstallMagpie).'
} else {
    $magpieExe = Join-Path $MagpieDir 'Magpie.exe'
    if (-not (Test-Path $magpieExe)) {
        $zip = Join-Path $env:TEMP "Magpie-$MagpieVersion-x64.zip"
        $url = "https://github.com/Blinue/Magpie/releases/download/$MagpieVersion/Magpie-$MagpieVersion-x64.zip"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
        $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $MagpieSha256) { Remove-Item $zip; throw "Magpie download checksum mismatch: $hash" }
        Expand-Archive $zip -DestinationPath $MagpieDir -Force
        Remove-Item $zip
        Write-Host "  installed Magpie $MagpieVersion to $MagpieDir"
    } else {
        Write-Host '  Magpie already installed.'
    }

    $cfg = Join-Path $env:LOCALAPPDATA 'Magpie\config\v4\config.json'
    Get-Process Magpie -ErrorAction SilentlyContinue | Stop-Process -Force
    if (-not (Test-Path $cfg)) {
        # Let Magpie write its default config once.
        $p = Start-Process $magpieExe -ArgumentList '-t' -PassThru
        for ($i = 0; $i -lt 30 -and -not (Test-Path $cfg); $i++) { Start-Sleep -Milliseconds 500 }
        Stop-Process $p -Force -ErrorAction SilentlyContinue
        Start-Sleep 1
    }
    if (-not (Test-Path $cfg)) { throw "Magpie did not create $cfg; start Magpie once, close it, and rerun." }

    Copy-Item $cfg "$cfg.bak" -Force
    $json = Get-Content $cfg -Raw | ConvertFrom-Json
    $profileJson = Join-Path $PSScriptRoot 'magpie-profile.json'
    $gameProfile = Get-Content $profileJson -Raw | ConvertFrom-Json
    $gameProfile.pathRule = $exe
    $gameProfile.launcherPath = Join-Path $GameDir 'Meesters van Macht.lnk'
    # The projector centres the 640x480 stage on a full-screen window: crop the border away.
    $screen = Get-PrimaryScreenSize
    $gameProfile.cropping.left = $gameProfile.cropping.right = [double](($screen.Width - 640) / 2)
    $gameProfile.cropping.top = $gameProfile.cropping.bottom = [double](($screen.Height - 480) / 2)
    Write-Host "  primary screen $($screen.Width)x$($screen.Height): crop $($gameProfile.cropping.left) / $($gameProfile.cropping.top) px"
    # Start from Magpie's own default profile so any fields we don't set keep valid defaults.
    $merged = $json.profiles[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    foreach ($prop in $gameProfile.PSObject.Properties) {
        if ($merged.PSObject.Properties[$prop.Name]) { $merged.($prop.Name) = $prop.Value }
        else { $merged | Add-Member $prop.Name $prop.Value }
    }
    $json.profiles = @($json.profiles[0]) + @($json.profiles | Select-Object -Skip 1 | Where-Object { $_.name -ne $gameProfile.name }) + @($merged)
    $json.allowScalingMaximized = $true   # the game's window covers the whole screen
    $json.autoCheckForUpdates = $false
    $text = $json | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($cfg, $text, (New-Object Text.UTF8Encoding $false))   # Magpie rejects a BOM
    Write-Host "  profile '$($gameProfile.name)' written to $cfg"
}

Write-Host "`nDone. Start the game with 'Meesters van Macht.lnk' in $GameDir." -ForegroundColor Green
