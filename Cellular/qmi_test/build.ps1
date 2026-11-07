[CmdletBinding()]
param(
    [string]$Ndk = $env:ANDROID_NDK_HOME
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $Ndk) {
    $sdkRoot = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
    $sdkNdk = Join-Path $sdkRoot 'ndk'
    $candidates = @()
    if (Test-Path $sdkNdk) {
        $candidates += Get-ChildItem $sdkNdk -Directory |
            Sort-Object Name -Descending |
            Select-Object -ExpandProperty FullName
    }
    $Ndk = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $Ndk) {
    throw 'ANDROID_NDK_HOME is not set and no NDK was found under the Android SDK.'
}

$cc = Join-Path $Ndk 'toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64-linux-android21-clang.cmd'
if (-not (Test-Path $cc)) {
    throw "Compiler not found: $cc"
}

$targets = @(
    'qmi_nas_test',
    'qmi_band_set',
    'qmi_probe',
    'qmi_lte_test',
    'qmi_restore_lte',
    'qmi_restore_nr',
    'qmi_set_n78',
    'dlopen_test'
)

foreach ($target in $targets) {
    $src = Join-Path $root "$target.c"
    $out = Join-Path $root $target
    if (-not (Test-Path $src)) {
        Write-Warning "skip missing source: $src"
        continue
    }
    Write-Host "CC $target"
    & $cc -O2 -o $out $src -ldl
    if ($LASTEXITCODE -ne 0) {
        throw "build failed: $target"
    }
}

Write-Host 'done.'
