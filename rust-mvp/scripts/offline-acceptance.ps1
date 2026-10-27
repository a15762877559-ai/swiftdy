param([string]$EvidenceDir = (Join-Path $PSScriptRoot '../acceptance'), [string]$TaskId = 'DOUSTUDIOKIT_WINDOWS_RUST_MVP_01')
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$evidence = [IO.Path]::GetFullPath($EvidenceDir)
New-Item -ItemType Directory -Force -Path $evidence | Out-Null
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureRoot = Join-Path $tempParent ('doustudio-rust-offline-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$oldFixture = $env:DOUSTUDIO_FIXTURE_MP4
$oldOffline = $env:DOUSTUDIO_OFFLINE_ONLY
$oldAcceptanceEvidence = $env:DOUSTUDIO_ACCEPTANCE_TEST_EVIDENCE
$summary = [ordered]@{ task=$TaskId; os=[Environment]::OSVersion.VersionString; real_worklist='NOT_RUN'; real_media='NOT_RUN'; production_allowlist='EMPTY'; no_watermark='NOT_VERIFIED'; fixture_cleanup='NOT_RUN'; checks=@() }
function Invoke-Check([string]$Name, [string]$Program, [string[]]$Arguments) {
    & $Program @Arguments 2>&1 | Tee-Object -FilePath (Join-Path $evidence ($Name + '.log')) | Out-Host
    $code = $LASTEXITCODE
    $summary.checks += @{name=$Name; exit_code=$code; status=$(if ($code -eq 0) {'PASS'} else {'FAIL'})}
    if ($code -ne 0) { throw "Offline check failed: $Name" }
}
Push-Location $project
try {
    $env:DOUSTUDIO_OFFLINE_ONLY = '1'
    $env:DOUSTUDIO_ACCEPTANCE_TEST_EVIDENCE = $evidence
    $env:DOUSTUDIO_FIXTURE_MP4 = Join-Path $fixtureRoot 'synthetic.mp4'
    Invoke-Check 'rust-version' 'rustc' @('--version')
    Invoke-Check 'ffmpeg-version' 'ffmpeg' @('-version')
    Invoke-Check 'synthetic-fixture' 'ffmpeg' @('-hide_banner','-loglevel','error','-f','lavfi','-i','testsrc2=size=64x64:rate=30','-frames:v','30','-c:v','libx264','-pix_fmt','yuv420p','-movflags','+faststart','-y',$env:DOUSTUDIO_FIXTURE_MP4)
    Invoke-Check 'format' 'cargo' @('fmt','--all','--','--check')
    Invoke-Check 'build-release' 'cargo' @('build','--release','--locked','--offline')
    Invoke-Check 'clippy-production' 'cargo' @('clippy','--locked','--offline','--all-targets','--','-D','warnings')
    Invoke-Check 'clippy-offline' 'cargo' @('clippy','--locked','--offline','--features','offline-test','--all-targets','--','-D','warnings')
    Invoke-Check 'test-production' 'cargo' @('test','--locked','--offline','--','--test-threads=1')
    Invoke-Check 'test-offline' 'cargo' @('test','--locked','--offline','--features','offline-test','--','--test-threads=1')
    Invoke-Check 'windows-ctrl-c' 'python' @((Join-Path $PSScriptRoot 'test-windows-ctrl-c.py'),'--exe',(Join-Path $project 'target/debug/doustudio.exe'),'--evidence',(Join-Path $evidence 'windows-ctrl-c.json'))
    Invoke-Check 'cli-help' (Join-Path $project 'target/release/doustudio.exe') @('--help')
    Invoke-Check 'cli-acceptance-help' (Join-Path $project 'target/release/doustudio.exe') @('acceptance','--help')
    Invoke-Check 'cli-verify' (Join-Path $project 'target/release/doustudio.exe') @('verify',$env:DOUSTUDIO_FIXTURE_MP4)
    $summary.result='PASS'
} catch {
    $summary.result='FAIL'
    throw
} finally {
    Pop-Location
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ne $tempParent.TrimEnd('\') -or -not [IO.Path]::GetFileName($resolved).StartsWith('doustudio-rust-offline-')) { throw 'Fixture cleanup scope mismatch' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
    $summary.fixture_cleanup = $(if (Test-Path -LiteralPath $resolved) {'FAIL'} else {'PASS'})
    $env:DOUSTUDIO_FIXTURE_MP4=$oldFixture
    $env:DOUSTUDIO_OFFLINE_ONLY=$oldOffline
    $env:DOUSTUDIO_ACCEPTANCE_TEST_EVIDENCE=$oldAcceptanceEvidence
    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $evidence 'summary.json') -Encoding utf8
}
