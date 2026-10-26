# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 125hz
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
# ml1830: synthetic malformed transfer, no account data and no game launch.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$folder = Join-Path $repo '.build/tests'
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$handoff = Join-Path $folder 'invalid.auth'
$report = Join-Path $folder 'invalid-handoff.txt'
[IO.File]::WriteAllBytes($handoff, [Text.Encoding]::ASCII.GetBytes('invalid-fixture'))
$settings = @{
    MADEIRA_STEAM_HOST_PROBE = '1'
    MADEIRA_STEAM_HOST_SESSION = '1'
    MADEIRA_STEAM_HOST_LOGIN = '1'
    MADEIRA_STEAM_HOST_LAUNCH = '0'
    MADEIRA_STEAM_HOST_APPID = '123'
    MADEIRA_DOCK_AUTH_FILE = $handoff
    MADEIRA_STEAM_HOST_LOG = $report
    MADEIRA_STEAM_HOST_ACCOUNT = $null
    MADEIRA_STEAM_HOST_STEAMID = $null
}
$previous = @{}
try {
    foreach ($key in $settings.Keys) {
        $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $settings[$key], 'Process')
    }
    & (Join-Path $repo '.build/windows/dockhost-x86_64.exe') 2>$null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 37) { throw "Expected rejection 37, got $exitCode" }
    if (Test-Path -LiteralPath $handoff) { throw 'Malformed handoff was not consumed' }
    $text = [IO.File]::ReadAllText($report)
    if (!$text.Contains('session-native-handoff-invalid=1') -or
        $text.Contains('session-native-token-submitted') -or $text.Contains('session-cached-account-selected')) {
        throw 'Malformed handoff did not fail closed before login'
    }
    Write-Output 'PASS: malformed transfer consumed; no login, cached fallback or game launch'
} finally {
    foreach ($key in $previous.Keys) {
        [Environment]::SetEnvironmentVariable($key, $previous[$key], 'Process')
    }
    if (Test-Path -LiteralPath $handoff) { Remove-Item -LiteralPath $handoff }
}
