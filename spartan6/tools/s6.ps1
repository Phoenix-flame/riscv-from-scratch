<#
.SYNOPSIS
    Drive the Posedge One board from Windows -- program it, upload firmware,
    watch the console. The same verbs as the Makefile, minus the need for
    make, bash, or a /dev/ttyUSB* device node.

.DESCRIPTION
    Makefile target        Windows equivalent
    ---------------        ------------------
    make prog              .\tools\s6.cmd prog
    make prog-flash        .\tools\s6.cmd prog-flash
    make term              .\tools\s6.cmd term
    make upload PORT=...   .\tools\s6.cmd upload -Port COM4
    make bit-boot          .\tools\s6.cmd bit-boot

    s6.cmd is a wrapper around this script that works whatever the
    execution policy is; call s6.ps1 directly if yours allows it.

    The serial port is found automatically: the FT2232H's channel B is the
    UART, channel A is the JTAG programmer, and Windows names them both
    "USB Serial Port (COMn)". Pass -Port to override.

    Synthesis (make bit) is not here -- ISE 14.7 does that, and the .bit it
    produces is all this script needs.

.EXAMPLE
    .\tools\s6.cmd ports
    .\tools\s6.cmd prog
    .\tools\s6.cmd term
    .\tools\s6.cmd upload -Bin build\hello_app.bin -Port COM4
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'ports', 'prog', 'prog-flash', 'term', 'upload', 'bit-boot')]
    [string]$Command = 'help',

    [string]$Port,                       # COM4; omit to auto-detect
    [string]$Bit,                        # default syn\s6_top.bit
    [string]$Bin,                        # default build\hello_app.bin
    [int]$Baud = 115200,
    [string]$Entry = '0x800',
    [string]$FpgaPart = 'xc6slx9tqg144',   # only prog-flash needs it
    [switch]$NoTerm                      # upload without staying attached
)

$ErrorActionPreference = 'Stop'
$S6 = Split-Path -Parent $PSScriptRoot   # ...\spartan6

function Fail([string]$msg) {
    Write-Host ""
    Write-Host $msg -ForegroundColor Red
    exit 1
}

function Say([string]$msg) { Write-Host "[s6] $msg" -ForegroundColor Cyan }

# ---------------------------------------------------------------------
# Serial ports
# ---------------------------------------------------------------------
function Get-S6Ports {
    $devs = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '\(COM\d+\)' })
    $rows = @()
    foreach ($d in $devs) {
        $com  = ([regex]'\((COM\d+)\)').Match($d.Name).Groups[1].Value
        $id   = [string]$d.PNPDeviceID
        $chan = ''
        if ($id -match 'VID_0403\+PID_6010\+') {
            # FTDI appends A or B to the serial number, one per interface.
            if ($id -match 'VID_0403\+PID_6010\+[^\\]*B\\') { $chan = 'B - UART' }
            else                                            { $chan = 'A - JTAG' }
        }
        $rows += [pscustomobject]@{
            Port = $com; Channel = $chan; Name = $d.Name; DeviceId = $id
        }
    }
    $rows | Sort-Object { [int]($_.Port -replace '\D', '') }
}

function Resolve-S6Port([string]$want) {
    if ($want) { return $want }

    $ports = @(Get-S6Ports)
    if ($ports.Count -eq 0) {
        Fail @"
No COM ports found. Plug the board in, then look under "Ports (COM & LPT)"
in Device Manager. If nothing shows up there, install the FTDI VCP driver:
    https://ftdichip.com/drivers/vcp-drivers/
"@
    }

    $b = @($ports | Where-Object { $_.Channel -eq 'B - UART' })
    if ($b.Count -eq 1) {
        Say "port $($b[0].Port)  (FT2232H channel B)"
        return $b[0].Port
    }
    if ($ports.Count -eq 1) {
        Say "port $($ports[0].Port)  ($($ports[0].Name))"
        return $ports[0].Port
    }

    $list = ($ports | ForEach-Object { "    $($_.Port)  $($_.Name)" }) -join "`n"
    Fail "Several serial ports; pick one with -Port COMn:`n$list"
}

# ---------------------------------------------------------------------
# External tools
# ---------------------------------------------------------------------
function Get-S6Python {
    foreach ($c in @('python', 'py')) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        # The Microsoft Store stub in WindowsApps answers to the name but
        # only opens the Store, so ask it to actually run something.
        & $cmd.Source -c "import sys" 2>$null
        if ($LASTEXITCODE -eq 0) { return $cmd.Source }
    }
    Fail @"
No working python found on PATH.
Install it from https://python.org (tick "Add python.exe to PATH"), or:
    winget install Python.Python.3.12
"@
}

function Assert-Pyserial([string]$py) {
    & $py -c "import serial" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Fail "pyserial is missing. Install it with:`n    $py -m pip install pyserial"
    }
}

function Test-S6Loader([string]$exe) {
    # Being on PATH is not the same as being runnable. An
    # openFPGALoader.exe extracted on its own out of
    # mingw-w64-x86_64-openFPGALoader-*.pkg.tar.zst has none of the MSYS2
    # DLLs beside it, so Windows kills it with 0xC0000135
    # (STATUS_DLL_NOT_FOUND) before it prints a single character -- which
    # then reads, further down, as a Zadig problem it is not. Ask it for
    # its version and see whether it survives.
    try { & $exe '--Version' *>$null } catch { return $false }
    return ($LASTEXITCODE -eq 0)
}

function Get-S6Loader {
    $candidates = @()
    $cmd = Get-Command openFPGALoader -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }

    # The Windows build ships as an MSYS2 package, so that is where it
    # normally lands; tools\openFPGALoader\ is the drop-it-here option.
    $candidates += @(
        "C:\msys64\mingw64\bin\openFPGALoader.exe",
        "C:\msys64\ucrt64\bin\openFPGALoader.exe",
        "C:\msys64\clang64\bin\openFPGALoader.exe",
        (Join-Path $PSScriptRoot "openFPGALoader\openFPGALoader.exe"),
        (Join-Path $PSScriptRoot "openFPGALoader\bin\openFPGALoader.exe"),
        "$env:ProgramFiles\openFPGALoader\openFPGALoader.exe",
        "${env:ProgramFiles(x86)}\openFPGALoader\openFPGALoader.exe",
        "$env:LOCALAPPDATA\Programs\openFPGALoader\openFPGALoader.exe",
        "$env:USERPROFILE\scoop\shims\openFPGALoader.exe",
        "$env:ProgramData\chocolatey\bin\openFPGALoader.exe"
    )

    $seen   = @{}
    $broken = @()
    foreach ($c in $candidates) {
        if (-not $c -or $seen.ContainsKey($c) -or -not (Test-Path $c)) { continue }
        $seen[$c] = $true
        if (Test-S6Loader $c) { return $c }
        $broken += $c
    }

    if ($broken.Count -gt 0) {
        Fail @"
openFPGALoader was found, but the copy on PATH will not start:

$(($broken | ForEach-Object { "    $_" }) -join "`n")

That is almost always an openFPGALoader.exe unpacked on its own out of
mingw-w64-x86_64-openFPGALoader-*.pkg.tar.zst. The exe alone is not
enough -- it needs the MSYS2 runtime beside it (libusb-1.0, libftdi1,
libstdc++-6, libgcc_s_seh-1, libwinpthread-1, zlib1). Install the
package properly and take the stray copy off PATH:

    winget install MSYS2.MSYS2
    C:\msys64\msys2_shell.cmd -mingw64 -c "pacman -S --noconfirm mingw-w64-x86_64-openFPGALoader"

This script looks in C:\msys64\mingw64\bin by itself, so nothing needs
to go on PATH.
"@
    }

    Fail @"
openFPGALoader was not found. There is no standalone Windows .exe --
upstream ships it as an MSYS2 package, so:

    winget install MSYS2.MSYS2
    C:\msys64\msys2_shell.cmd -mingw64 -c "pacman -S --noconfirm mingw-w64-x86_64-openFPGALoader"

This script looks in C:\msys64\mingw64\bin by itself, so nothing needs
to go on PATH.

Then hand JTAG (interface 0) to WinUSB with Zadig -- see
docs\programming.md, section "Windows". Leave interface 1 on the FTDI VCP
driver, or you lose the COM port this script talks to.
"@
}

function Invoke-Loader([string[]]$loaderArgs) {
    $ofl = Get-S6Loader
    Say "$ofl $($loaderArgs -join ' ')"

    # openFPGALoader colours its output with ANSI codes the Windows
    # console prints raw, and it exits 0 even on 'Can't program SPI
    # flash', so watch what it says rather than only what it returns.
    $esc = [char]27
    $said = New-Object System.Collections.ArrayList

    # The MSYS2 build shells out to cygpath to find its spiOverJtag
    # bitstreams, so MSYS2's /usr/bin has to be reachable. Appended,
    # never prepended: its find/sort/link would shadow Windows' own.
    $savedPath = $env:PATH
    $msysRoot = ($ofl -split '\\(mingw64|ucrt64|clang64)\\')[0]
    $usrBin = Join-Path $msysRoot 'usr\bin'
    if ((Test-Path $usrBin) -and ($env:PATH -notlike "*$usrBin*")) {
        $env:PATH = "$env:PATH;$usrBin"
    }

    try {
        & $ofl @loaderArgs 2>&1 | ForEach-Object {
            $line = ("$_" -replace "$esc\[[0-9;]*[A-Za-z]", "").TrimEnd()
            Write-Host $line
            [void]$said.Add($line)
        }
        $rc = $LASTEXITCODE
    } finally {
        $env:PATH = $savedPath
    }
    $complaints = @($said | Where-Object {
        $_ -match "Can't program|JTAG init failed|unable to open|not recognized|^Error|failed with"
    })
    if ($rc -ne 0 -or $complaints.Count -gt 0) {
        Fail @"
openFPGALoader did not do what was asked (exit $rc).

"unable to open ftdi device" means interface 0 is still bound to the
FTDI VCP driver: run Zadig, tick Options > List All Devices, select
"Dual RS232-HS (Interface 0)" -- interface 0, not 1 -- and replace its
driver with WinUSB.

"missing device-package information" means the -FpgaPart is wrong for
this board. It has to name a spiOverJtag bitstream that ships with
openFPGALoader; the LX9 on a Posedge One is xc6slx9tqg144.
"@
    }
}

function Invoke-S6Load([string[]]$loadArgs) {
    $py = Get-S6Python
    Assert-Pyserial $py
    # -u so the console still streams when the output is piped to a file.
    & $py '-u' (Join-Path $PSScriptRoot 's6load.py') @loadArgs
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------
switch ($Command) {

    'ports' {
        $ports = @(Get-S6Ports)
        if ($ports.Count -eq 0) { Say "no COM ports found"; break }
        $ports | Format-Table Port, Channel, Name -AutoSize
        Say "channel B is the console; channel A is JTAG, and disappears from this list once Zadig gives it to WinUSB"
    }

    'prog' {
        if (-not $Bit) { $Bit = Join-Path $S6 'syn\s6_top.bit' }
        if (-not (Test-Path $Bit)) {
            Fail "$Bit is missing -- build it with ISE first (make bit, or xtclsh build.tcl)."
        }
        Say "loading $Bit into the FPGA (volatile -- gone at power-off)"
        Invoke-Loader @('-c', 'ft2232', $Bit)
    }

    'prog-flash' {
        if (-not $Bit) { $Bit = Join-Path $S6 'syn\s6_top.bit' }
        if (-not (Test-Path $Bit)) {
            Fail "$Bit is missing -- build it with ISE first (make bit, or xtclsh build.tcl)."
        }
        Say "writing $Bit to SPI flash (survives power-off)"
        Invoke-Loader @('-c', 'ft2232', '--fpga-part', $FpgaPart, '-f', $Bit)
    }

    'term' {
        $p = Resolve-S6Port $Port
        Invoke-S6Load @('-p', $p, '-b', "$Baud", '--term')
    }

    'upload' {
        if (-not $Bin) { $Bin = Join-Path $S6 'build\hello_app.bin' }
        if (-not (Test-Path $Bin)) {
            Fail @"
$Bin is missing.

It comes from the RISC-V toolchain, which normally lives on the same
machine as ISE:

    NAME=hello_app LDSCRIPT=sw/link_app.ld ./sw/build.sh sw/hello.c   (= make app)

Copy the resulting .bin over, or point at another one with -Bin.
"@
        }
        $p = Resolve-S6Port $Port
        $a = @('-p', $p, '-b', "$Baud", '-e', $Entry, $Bin)
        if (-not $NoTerm) { $a += '--term' }
        Invoke-S6Load $a
    }

    'bit-boot' {
        $boot = Join-Path $S6 'sw\boot.hex'
        $fw   = Join-Path $S6 'sw\firmware.hex'
        if (-not (Test-Path $boot)) {
            Fail "sw\boot.hex is missing -- build it with ./sw/build.sh sw/boot.c (= make boot)."
        }
        Copy-Item $boot $fw -Force
        Say "sw\firmware.hex now holds the bootloader"
        Write-Host @"
    Next: re-run synthesis so the bootloader is baked into the block RAM
    (on the ISE box: make bit), then  .\tools\s6.ps1 prog  followed by
    .\tools\s6.ps1 upload.

    To go back to the plain firmware:  git checkout -- sw/firmware.hex
"@
    }

    default {
        Get-Help $PSCommandPath -Detailed
        exit 0
    }
}
