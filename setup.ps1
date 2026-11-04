# Вызывается из install.bat. Сам по себе его запускать не нужно.
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Shortcuts', 'RawAccel', 'Elevate')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
}

function New-SiteShortcut {
    param(
        [string]$Name,
        [string]$Url
    )

    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) {
        throw 'Не удалось найти папку рабочего стола.'
    }

    $path = Join-Path $desktop ($Name + '.url')
    Set-Content -LiteralPath $path -Encoding ASCII -Value @(
        '[InternetShortcut]'
        "URL=$Url"
    )
    Write-Host "Ярлык: $path"
}

function Install-RawAccel {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw 'Драйвер Raw Accel ставится только с правами администратора. Запустите install.bat.'
    }

    $dest = Join-Path $env:ProgramFiles 'RawAccel'
    $zip = Join-Path $env:TEMP 'RawAccel-latest.zip'
    $staging = Join-Path $env:TEMP 'RawAccel-staging'

    Write-Host 'Скачиваю последний официальный Raw Accel с GitHub...'
    $release = Invoke-RestMethod -Headers @{ 'User-Agent' = 'install-bat' } -Uri 'https://api.github.com/repos/RawAccelOfficial/rawaccel/releases/latest'
    $asset = $release.assets | Where-Object { $_.name -like 'RawAccel_*.zip' } | Select-Object -First 1
    if (-not $asset) {
        throw 'В последнем релизе нет архива RawAccel_*.zip.'
    }

    Write-Host ("Файл: {0} ({1})" -f $asset.name, $release.tag_name)
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip

    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
    Expand-Archive -Path $zip -DestinationPath $staging -Force

    $installer = Get-ChildItem -LiteralPath $staging -Recurse -Filter 'installer.exe' | Select-Object -First 1
    if (-not $installer) {
        throw 'В архиве нет installer.exe.'
    }

    $sourceDir = $installer.DirectoryName
    Get-Process -Name 'rawaccel' -ErrorAction SilentlyContinue | Stop-Process -Force
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item -Path (Join-Path $sourceDir '*') -Destination $dest -Recurse -Force

    $installed = Join-Path $dest 'installer.exe'
    $driver = Join-Path $dest 'driver\rawaccel.sys'
    $gui = Join-Path $dest 'rawaccel.exe'
    if (-not (Test-Path -LiteralPath $installed)) {
        throw 'installer.exe не скопировался.'
    }
    if (-not (Test-Path -LiteralPath $driver)) {
        throw 'driver\rawaccel.sys не скопировался.'
    }
    if (-not (Test-Path -LiteralPath $gui)) {
        throw 'rawaccel.exe не скопировался.'
    }

    Write-Host 'Ставлю драйвер Raw Accel...'
    Push-Location -LiteralPath $dest
    try {
        & .\installer.exe
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($code -ne 0 -and $code -ne 3010 -and $code -ne 1641) {
        throw "installer.exe завершился с кодом $code"
    }

    $desktop = [Environment]::GetFolderPath('Desktop')
    $shell = New-Object -ComObject WScript.Shell
    $linkPath = Join-Path $desktop 'Raw Accel.lnk'
    $link = $shell.CreateShortcut($linkPath)
    $link.TargetPath = $gui
    $link.WorkingDirectory = $dest
    $link.Description = 'Raw Accel'
    $link.Save()

    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "Raw Accel $($release.tag_name) установлен."
    Write-Host 'Перезагрузите компьютер, чтобы драйвер заработал.'
    Write-Host "Ярлык: $linkPath"
}

function Invoke-ElevatedInstaller {
    $bat = Join-Path $PSScriptRoot 'install.bat'
    if (-not (Test-Path -LiteralPath $bat)) {
        throw 'Рядом с setup.ps1 нет install.bat.'
    }

    # cmd.exe strips one pair of quotes from /c. The extra quotes keep paths with spaces intact.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.Arguments = '/d /c ""' + $bat + '" --elevated"'
    $psi.UseShellExecute = $true
    $psi.Verb = 'runas'

    try {
        $proc = [Diagnostics.Process]::Start($psi)
    } catch {
        Write-Host 'Запрос администратора отменён или не удался.'
        Write-Host $_.Exception.Message
        exit 1
    }

    $null = $proc.WaitForExit()
    exit $proc.ExitCode
}

switch ($Action) {
    'Shortcuts' {
        New-SiteShortcut -Name 'SoundCloud' -Url 'https://soundcloud.com/'
        New-SiteShortcut -Name 'GravaStar' -Url 'https://www.gravastar.com/'
    }
    'RawAccel' {
        Install-RawAccel
    }
    'Elevate' {
        Invoke-ElevatedInstaller
    }
}
