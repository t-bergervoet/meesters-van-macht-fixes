<#
.SYNOPSIS
    Makes "De Meesters van Macht" (1997, Macromedia Director 6) run on 64-bit Windows 10/11.

.DESCRIPTION
    Applies every fix from this repo to an installed copy of the game. Safe to run more than once:
    each step checks whether it has already been applied. Originals are kept as *.orig.

      1. Restore files missing from the install (PUTCURS.DLL, sound files) from the CD image.
      2. Patch Data\Global\scripts.cst so the game no longer creates the 16-bit Putcurs XObject.
      3. Patch MvM.exe's projector header so the game keeps running when it loses focus.
      4. Disable the 1996 DirectSound Xtra (deadlocks on modern Windows).
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
$GameDir = (Resolve-Path $GameDir).Path
$exe = Join-Path $GameDir 'MvM.exe'
if (-not (Test-Path $exe)) { throw "MvM.exe not found in $GameDir" }

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
    [byte[]] ($hex -split '(..)' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) })
}

# ---------------------------------------------------------------------------------------------
Write-Step '1. Restore missing files from the CD image'
if (-not $DiscImage) {
    Write-Host 'No -DiscImage given; skipping. (Xtras\PUTCURS.DLL must exist or the game stops with "XLib file not found".)'
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
        & $SevenZip x $iso 'MvM\Data\*' 'MvM\Xtras\*' "-o$tmp\x" -y | Out-Null
        $root = Join-Path $tmp 'x\MvM'
        $restored = 0
        Get-ChildItem -Recurse -File $root | ForEach-Object {
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
        Write-Host "  $restored file(s) restored."
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------------------------
Write-Step '2. Patch scripts.cst: skip the 16-bit Putcurs XObject'
# initCursorObject compiles "set myMouse = Putcurs(mNew)" to:
#   85 0156 pushsymb mnew | 43 01 pusharglist 1 | 86 0155 pushvarref Putcurs | 58 01 objcallv4 | 8f 0151 setglobal myMouse
# Replaced with: 03 push0 | 93 0009 jmp +9 (to the setglobal) | 6 filler bytes  => set myMouse = 0
# moveTheCursor already does "if not objectp(myMouse) then return", so cursor warping is skipped cleanly.
$cst = Join-Path $GameDir 'Data\Global\scripts.cst'
$orig = ConvertFrom-Hex '850156430186015558018f0151'
$patched = ConvertFrom-Hex '039300090000000000008f0151'
$bytes = [IO.File]::ReadAllBytes($cst)
$todo = @(Find-Bytes $bytes $orig)
$done = @(Find-Bytes $bytes $patched)
if ($todo.Count -eq 0 -and $done.Count -gt 0) {
    Write-Host '  already patched.'
} elseif ($todo.Count -eq 0) {
    throw 'scripts.cst: Putcurs bytecode not found - unknown version of the game?'
} else {
    Backup-Once $cst
    foreach ($p in $todo) { [Array]::Copy($patched, 0, $bytes, $p, $patched.Length) }
    [IO.File]::WriteAllBytes($cst, $bytes)
    Write-Host "  patched $($todo.Count) location(s) at offset(s) $($todo -join ', ')."
}

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
Write-Step '4. Disable the DirectSound Xtra'
# DSOUND_R.X32 (1996) deadlocks on the first menu click. Without it the game's own
# initDirectSound falls back to Director's built-in sound.
$xtra = Join-Path $GameDir 'Xtras\DSOUND_R.X32'
if (Test-Path $xtra) {
    $disabledDir = Join-Path $GameDir 'Xtras (disabled)'
    New-Item -ItemType Directory -Force $disabledDir | Out-Null
    Move-Item $xtra $disabledDir -Force
    Write-Host '  moved to "Xtras (disabled)".'
} else {
    Write-Host '  already disabled.'
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
