# PowerShell: package the Windows lhasa build into a dist archive.
# Mirrors scripts/package.sh for the Windows / MinGW runner.
#
#   TARGET    e.g. x86_64-windows
#   BUILD_DIR (default ..\build)
#   DIST      (default ..\dist)
#
# Output: dist\lhasa-$TARGET.zip + .sha256.

$ErrorActionPreference = "Stop"

$ROOT = (Resolve-Path -Path "$PSScriptRoot\..").Path
$BUILD_DIR = if ($env:BUILD_DIR) { $env:BUILD_DIR } else { Join-Path $ROOT "build" }
$LHASA_SRC = if ($env:LHASA_SRC) { $env:LHASA_SRC } else { Join-Path $ROOT "upstream\lhasa" }
$DIST = if ($env:DIST) { $env:DIST } else { Join-Path $ROOT "dist" }
$TARGET = if ($env:TARGET) { $env:TARGET } else { Throw "set TARGET, e.g. x86_64-windows" }

$BIN = Join-Path $BUILD_DIR "src\lha.exe"
if (-not (Test-Path $BIN)) { Throw "error: $BIN not built (out-of-tree BUILD_DIR=$BUILD_DIR)" }

$MAN_SRC = Join-Path $LHASA_SRC "doc\lha.1"
if (-not (Test-Path $MAN_SRC)) { Throw "error: $MAN_SRC not found" }

$STAGE = Join-Path $DIST "lhasa-$TARGET"
if (Test-Path $STAGE) { Remove-Item -Recurse -Force $STAGE }
New-Item -ItemType Directory -Force -Path (Join-Path $STAGE "bin")       | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $STAGE "man\man1")  | Out-Null

Copy-Item $BIN (Join-Path $STAGE "bin\lha.exe")
Copy-Item $MAN_SRC (Join-Path $STAGE "man\man1\lha.1")

# README.
$readme = @'
# lhasa — single-binary release (Windows)

Self-contained archive from https://github.com/ljh-sh/lhasa (release tag).
The wrapper LICENSE and NOTICE live there; the `lha.exe` binary carries
the upstream ISC license from Simon Howard.

The `lha` binary name is intentional: lhasa ships an interface-
compatible `lha` replacement for non-free upstream LHa for UNIX.

Install (optional, manual):

    Copy bin\lha.exe to a directory on your PATH, e.g. C:\Windows\System32.
    Then:  lha --version
'@
Set-Content -Path (Join-Path $STAGE "README.md") -Value $readme -Encoding UTF8

# Zip archive.
if (-not (Test-Path $DIST)) { New-Item -ItemType Directory -Force -Path $DIST | Out-Null }
$ARCHIVE = Join-Path $DIST "lhasa-$TARGET.zip"
if (Test-Path $ARCHIVE) { Remove-Item $ARCHIVE }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
	(Join-Path $DIST ("lhasa-$TARGET")),
	$ARCHIVE
)

# SHA256 — keyed basename for portability.
$hash = (Get-FileHash -Algorithm SHA256 -Path $ARCHIVE).Hash.ToLower()
"$hash  lhasa-$TARGET.zip" | Set-Content -Path "$ARCHIVE.sha256" -Encoding ASCII

Write-Host "==> $ARCHIVE"
Write-Host "==> $ARCHIVE.sha256"
