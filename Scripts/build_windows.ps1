param(
    [ValidateSet("build", "test", "publish", "installer", "run")]
    [string]$Command = "build",

    [ValidateSet("win-x64", "win-arm64")]
    [string]$Runtime = "win-x64",

    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",

    [string]$Version = "0.32.5",

    [switch]$NoPublish,

    [switch]$InstallInno
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$appProject = Join-Path $root "Windows/CodexBar.Windows/CodexBar.Windows.csproj"
$testProject = Join-Path $root "Windows/CodexBar.Windows.Tests/CodexBar.Windows.Tests.csproj"
$publishDir = Join-Path $root "publish/windows/$Runtime"

function Resolve-InnoCompiler {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    if ($InstallInno) {
        winget install --id JRSoftware.InnoSetup -e --accept-source-agreements --accept-package-agreements --disable-interactivity
        if ($LASTEXITCODE -ne 0) {
            throw "winget failed to install Inno Setup."
        }
        return Resolve-InnoCompiler
    }

    throw "Inno Setup compiler (ISCC.exe) was not found. Install it, or rerun with -InstallInno."
}

function Convert-RuntimeToArch {
    if ($Runtime -eq "win-arm64") {
        return "arm64"
    }

    return "x64"
}

switch ($Command) {
    "build" {
        dotnet build $appProject -c $Configuration -r $Runtime -p:Version=$Version
    }
    "test" {
        dotnet test $testProject -c $Configuration --verbosity normal
    }
    "publish" {
        Remove-Item -LiteralPath $publishDir -Recurse -Force -ErrorAction SilentlyContinue
        dotnet publish $appProject -c $Configuration -r $Runtime --self-contained true `
            -p:Version=$Version `
            -p:PublishSingleFile=true `
            -p:IncludeNativeLibrariesForSelfExtract=true `
            -p:PublishReadyToRun=true `
            -o $publishDir
    }
    "installer" {
        if (-not $NoPublish) {
            & $PSCommandPath publish -Runtime $Runtime -Configuration $Configuration -Version $Version
            if ($LASTEXITCODE -ne 0) {
                exit $LASTEXITCODE
            }
        }

        $exePath = Join-Path $publishDir "CodexBar.Windows.exe"
        if (-not (Test-Path -LiteralPath $exePath)) {
            throw "Missing published tray executable at $exePath. Rerun without -NoPublish."
        }

        $iscc = Resolve-InnoCompiler
        $arch = Convert-RuntimeToArch
        & $iscc "/DMyAppVersion=$Version" "/DMyAppArch=$arch" "/Dpublish=$publishDir" (Join-Path $root "installer.iss")
        if ($LASTEXITCODE -ne 0) {
            throw "ISCC failed for $Runtime."
        }
    }
    "run" {
        dotnet run --project $appProject -c Debug
    }
}
