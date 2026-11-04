# Вызывается из install.bat. Сам по себе его запускать не нужно.
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Shortcuts', 'RawAccel', 'Elevate', 'EnableAutostart')]
    [string]$Action,

    [switch]$IncludeSystemApps
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

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Find-LatestFile {
    param([string[]]$Patterns)

    $hits = foreach ($pattern in $Patterns) {
        Get-Item -Path $pattern -ErrorAction SilentlyContinue
    }
    $file = @($hits) | Where-Object { $_ -and -not $_.PSIsContainer } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($file) { return $file.FullName }
    return $null
}

function Enable-StartupApproved {
    param(
        [string]$FolderName,
        [string]$ValueName
    )

    $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\' + $FolderName
    if (-not (Test-Path -LiteralPath $base)) {
        New-Item -Path $base -Force | Out-Null
    }
    # 02 00 00 00 means the startup entry is enabled in Task Manager.
    $enabled = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    New-ItemProperty -Path $base -Name $ValueName -PropertyType Binary -Value $enabled -Force | Out-Null
}

function Set-RunEntry {
    param(
        [string]$Name,
        [string]$Command
    )

    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (-not (Test-Path -LiteralPath $run)) {
        New-Item -Path $run -Force | Out-Null
    }
    New-ItemProperty -Path $run -Name $Name -Value $Command -PropertyType String -Force | Out-Null
    Enable-StartupApproved -FolderName 'Run' -ValueName $Name
    Write-Host "Автозагрузка: $Name"
}

function New-StartupUrl {
    param(
        [string]$Name,
        [string]$Url
    )

    $startup = [Environment]::GetFolderPath('Startup')
    if ([string]::IsNullOrWhiteSpace($startup)) {
        throw 'Не удалось найти папку автозагрузки.'
    }
    $fileName = $Name + '.url'
    $path = Join-Path $startup $fileName
    Set-Content -LiteralPath $path -Encoding ASCII -Value @(
        '[InternetShortcut]'
        "URL=$Url"
    )
    Enable-StartupApproved -FolderName 'StartupFolder' -ValueName $fileName
    Write-Host "Автозагрузка: $path"
}

function New-StartupShortcut {
    param(
        [string]$Name,
        [string]$Target,
        [string]$WorkDir
    )

    $startup = [Environment]::GetFolderPath('Startup')
    $fileName = $Name + '.lnk'
    $path = Join-Path $startup $fileName
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($path)
    $link.TargetPath = $Target
    $link.WorkingDirectory = $WorkDir
    $link.Description = $Name
    $link.WindowStyle = 7
    $link.Save()
    Enable-StartupApproved -FolderName 'StartupFolder' -ValueName $fileName
    Write-Host "Автозагрузка: $path"
}

function Enable-RazerServices {
    if (-not (Test-IsAdmin)) { return }

    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object {
        ($_.Name -match '(?i)razer|synapse' -or $_.DisplayName -match '(?i)razer|synapse') -and
        $_.Name -notmatch '(?i)rawaccel' -and
        $_.DisplayName -notmatch '(?i)rawaccel'
    }
    foreach ($service in $services) {
        try {
            Set-Service -Name $service.Name -StartupType Automatic -ErrorAction Stop
            if ($service.Status -ne 'Running') {
                Start-Service -Name $service.Name -ErrorAction SilentlyContinue
            }
            Write-Host "Служба запускается с Windows: $($service.DisplayName)"
        } catch {
            Write-Host "Службу $($service.DisplayName) не удалось поставить в автозапуск: $($_.Exception.Message)"
        }
    }
}

function Enable-InstalledAutostart {
    param([switch]$IncludeSystemApps)

    $spotify = Find-LatestFile -Patterns @(
        (Join-Path $env:APPDATA 'Spotify\Spotify.exe')
        (Join-Path $env:LOCALAPPDATA 'Spotify\Spotify.exe')
    )
    if ($spotify) {
        Set-RunEntry -Name 'Spotify' -Command ('"{0}" --autostart --minimized' -f $spotify)
    } else {
        Write-Host 'Spotify.exe ещё нет, запись автозагрузки для него пропущена.'
    }

    $figma = Find-LatestFile -Patterns @(
        (Join-Path $env:LOCALAPPDATA 'Figma\Figma.exe')
        (Join-Path $env:LOCALAPPDATA 'Figma\app-*\Figma.exe')
        (Join-Path $env:ProgramFiles 'Figma\Figma.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Figma\Figma.exe')
    )
    if ($figma) {
        Set-RunEntry -Name 'Figma' -Command ('"{0}"' -f $figma)
    } else {
        Write-Host 'Figma.exe ещё нет, запись автозагрузки для него пропущена.'
    }

    $figmaAgent = Find-LatestFile -Patterns @(
        (Join-Path $env:LOCALAPPDATA 'FigmaAgent\figma_agent.exe')
        (Join-Path $env:LOCALAPPDATA 'Figma\FigmaAgent.exe')
    )
    if ($figmaAgent) {
        Set-RunEntry -Name 'FigmaAgent' -Command ('"{0}"' -f $figmaAgent)
    }

    $razer = Find-LatestFile -Patterns @(
        (Join-Path $env:ProgramFiles 'Razer\RazerAppEngine\RazerAppEngine.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Razer\RazerAppEngine\RazerAppEngine.exe')
    )
    if ($razer) {
        $razerCommand = '"{0}" --url-params=apps=synapse --launch-force-hidden=synapse --autoStart=1' -f $razer
        Set-RunEntry -Name 'RazerAppEngine' -Command $razerCommand
    } elseif ($IncludeSystemApps) {
        Write-Host 'RazerAppEngine.exe ещё нет, запись автозагрузки для него пропущена.'
    }

    $rawAccel = Find-LatestFile -Patterns @(
        (Join-Path $env:ProgramFiles 'RawAccel\rawaccel.exe')
    )
    if ($rawAccel) {
        New-StartupShortcut -Name 'Raw Accel' -Target $rawAccel -WorkDir (Split-Path -Parent $rawAccel)
    } elseif ($IncludeSystemApps) {
        Write-Host 'rawaccel.exe ещё нет, ярлык автозагрузки для него пропущен.'
    }

    New-StartupUrl -Name 'SoundCloud' -Url 'https://soundcloud.com/'
    New-StartupUrl -Name 'GravaStar' -Url 'https://www.gravastar.com/'
    Enable-GraphiteClubAutostart
    Enable-RazerServices
}

function Find-GraphiteClubExe {
    $roots = @(
        $env:LOCALAPPDATA
        $env:APPDATA
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    foreach ($root in $roots) {
        $hit = Get-ChildItem -LiteralPath $root -Filter '*.exe' -Recurse -Depth 4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match '(?i)graphite' -and
                $_.Name -notmatch '(?i)setup|uninstall|update'
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Test-AutostartMatches {
    param([string]$Pattern)

    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path -LiteralPath $run) {
        $item = Get-Item -LiteralPath $run
        foreach ($name in $item.GetValueNames()) {
            $value = [string]$item.GetValue($name)
            if ($name -match $Pattern -or $value -match $Pattern) { return $true }
        }
    }

    $startup = [Environment]::GetFolderPath('Startup')
    if ($startup -and (Test-Path -LiteralPath $startup)) {
        $link = Get-ChildItem -LiteralPath $startup -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $Pattern } |
            Select-Object -First 1
        if ($link) { return $true }
    }
    return $false
}

function Enable-GraphiteClubAutostart {
    if (Test-AutostartMatches -Pattern '(?i)graphite') { return }

    $exe = Find-GraphiteClubExe
    if (-not $exe) { return }
    Set-RunEntry -Name 'Graphite Club' -Command ('"{0}"' -f $exe)
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
    'EnableAutostart' {
        Enable-InstalledAutostart -IncludeSystemApps:$IncludeSystemApps
    }
}
