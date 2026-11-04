# Вызывается из install.bat. Сам по себе его запускать не нужно.
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Shortcuts', 'RawAccel', 'Elevate', 'EnableAutostart', 'UserApps', 'ResolveWinget')]
    [string]$Action,

    [switch]$IncludeSystemApps
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
}

function Get-CandidateDesktopPaths {
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($key in @(
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
        )) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $raw = (Get-ItemProperty -LiteralPath $key -Name Desktop -ErrorAction SilentlyContinue).Desktop
        if (-not $raw) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables([string]$raw)
        if ($expanded -and (Test-Path -LiteralPath $expanded)) { $found.Add($expanded) }
    }
    $known = [Environment]::GetFolderPath('Desktop')
    if ($known -and (Test-Path -LiteralPath $known)) { $found.Add($known) }
    $candidates = @(
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'OneDrive\Desktop'),
        (Join-Path $env:USERPROFILE 'OneDrive\Рабочий стол')
    )
    if ($env:OneDrive) {
        $candidates += (Join-Path $env:OneDrive 'Desktop')
        $candidates += (Join-Path $env:OneDrive 'Рабочий стол')
    }
    if ($env:OneDriveConsumer) {
        $candidates += (Join-Path $env:OneDriveConsumer 'Desktop')
        $candidates += (Join-Path $env:OneDriveConsumer 'Рабочий стол')
    }
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) { $found.Add($path) }
    }
    return @($found | ForEach-Object { $_.TrimEnd('\') } | Select-Object -Unique)
}

function Test-SameDirectory {
    param([string]$Left, [string]$Right)
    if (-not $Left -or -not $Right) { return $false }
    $a = [IO.Path]::GetFullPath($Left).TrimEnd('\').ToLowerInvariant()
    $b = [IO.Path]::GetFullPath($Right).TrimEnd('\').ToLowerInvariant()
    if ($a -eq $b) { return $true }
    foreach ($path in @($Left, $Right)) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if (-not $item -or -not $item.Target) { continue }
        foreach ($target in @($item.Target)) {
            try {
                $full = [IO.Path]::GetFullPath([string]$target).TrimEnd('\').ToLowerInvariant()
            } catch {
                continue
            }
            if ($full -eq $a -or $full -eq $b) { return $true }
        }
    }
    return $false
}

function Get-DesktopPath {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    if (Test-Path -LiteralPath $key) {
        $raw = (Get-ItemProperty -LiteralPath $key -Name Desktop -ErrorAction SilentlyContinue).Desktop
        if ($raw) {
            $expanded = [Environment]::ExpandEnvironmentVariables([string]$raw)
            if ($expanded -and (Test-Path -LiteralPath $expanded)) { return $expanded.TrimEnd('\') }
        }
    }
    $known = [Environment]::GetFolderPath('Desktop')
    if ($known -and (Test-Path -LiteralPath $known)) { return $known.TrimEnd('\') }
    throw 'Не удалось найти папку рабочего стола.'
}

function Get-ShortcutProduct {
    param($Item, $Shell)
    $name = [IO.Path]::GetFileNameWithoutExtension($item.Name)
    $blob = $name
    if ($Item.Extension -eq '.lnk') {
        $link = $Shell.CreateShortcut($Item.FullName)
        $blob = $name + ' ' + [string]$link.TargetPath + ' ' + [string]$link.Arguments
    } elseif ($Item.Extension -eq '.url') {
        $blob = $name + ' ' + ((Get-Content -LiteralPath $Item.FullName -ErrorAction SilentlyContinue) -join ' ')
    }
    if ($blob -match '(?i)figma') { return 'figma' }
    if ($blob -match '(?i)graphite') { return 'graphite' }
    if ($blob -match '(?i)spotify') { return 'spotify' }
    if ($blob -match '(?i)rawaccel|raw accel') { return 'rawaccel' }
    if ($blob -match '(?i)razer|synapse') { return 'razer' }
    if ($blob -match '(?i)soundcloud') { return 'soundcloud' }
    if ($blob -match '(?i)gravastar') { return 'gravastar' }
    return $null
}

function Remove-DuplicateDesktopShortcuts {
    $primary = Get-DesktopPath
    $shell = New-Object -ComObject WScript.Shell
    foreach ($dir in (Get-CandidateDesktopPaths)) {
        if (Test-SameDirectory $dir $primary) { continue }
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            if ($item.Extension -notin '.lnk', '.url') { continue }
            $product = Get-ShortcutProduct -Item $item -Shell $shell
            if (-not $product) { continue }
            Remove-Item -LiteralPath $item.FullName -Force
            Write-Host "Удалён лишний ярлык: $($item.FullName)"
        }
    }

    $groups = @{}
    foreach ($item in @(Get-ChildItem -LiteralPath $primary -Force -ErrorAction SilentlyContinue)) {
        if ($item.Extension -notin '.lnk', '.url') { continue }
        $product = Get-ShortcutProduct -Item $item -Shell $shell
        if (-not $product) { continue }
        if (-not $groups.ContainsKey($product)) { $groups[$product] = @() }
        $groups[$product] += $item
    }
    foreach ($product in @($groups.Keys)) {
        $items = @($groups[$product])
        if ($items.Count -le 1) { continue }
        $keep = $items | Sort-Object Name | Select-Object -First 1
        foreach ($extra in $items) {
            if ($extra.FullName -eq $keep.FullName) { continue }
            Remove-Item -LiteralPath $extra.FullName -Force
            Write-Host "Удалён повтор: $($extra.FullName)"
        }
    }
}

function Get-BundledIconPath {
    param([string]$IconName)

    $source = Join-Path $PSScriptRoot (Join-Path 'icons' $IconName)
    if (-not (Test-Path -LiteralPath $source)) { return $null }
    $dir = Join-Path $env:LOCALAPPDATA 'SoftForGraphite\icons'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $dest = Join-Path $dir $IconName
    Copy-Item -LiteralPath $source -Destination $dest -Force
    return $dest
}

function New-SiteShortcut {
    param(
        [string]$Name,
        [string]$Url,
        [string]$IconName
    )

    $desktop = Get-DesktopPath
    $path = Join-Path $desktop ($Name + '.url')
    $lines = @(
        '[InternetShortcut]'
        "URL=$Url"
    )
    $icon = $null
    if ($IconName) { $icon = Get-BundledIconPath -IconName $IconName }
    if ($icon) {
        $lines += "IconFile=$icon"
        $lines += 'IconIndex=0'
        $lines += '[{000214A0-0000-0000-C000-000000000046}]'
        $lines += 'Prop3=19,0'
    }
    Set-Content -LiteralPath $path -Encoding ASCII -Value $lines
    Write-Host "Ярлык: $path"
}

function Update-DesktopIcons {
    if (-not ('DesktopNotify.Native' -as [type])) {
        Add-Type -Namespace DesktopNotify -Name Native -MemberDefinition @'
[DllImport("shell32.dll")]
public static extern void SHChangeNotify(int eventId, uint flags, System.IntPtr item1, System.IntPtr item2);
'@
    }
    [DesktopNotify.Native]::SHChangeNotify(0x8000000, 0x1000, [IntPtr]::Zero, [IntPtr]::Zero)
}

function New-DesktopShortcut {
    param(
        [string]$Name,
        [string]$Target,
        [string]$WorkDir
    )

    if (-not (Test-Path -LiteralPath $Target)) { return }
    $desktop = Get-DesktopPath
    $shell = New-Object -ComObject WScript.Shell
    $product = switch -Regex ($Name) {
        '(?i)figma' { 'figma' }
        '(?i)graphite' { 'graphite' }
        '(?i)spotify' { 'spotify' }
        '(?i)raw accel' { 'rawaccel' }
        '(?i)razer|synapse' { 'razer' }
        default { $null }
    }
    if ($product) {
        foreach ($item in @(Get-ChildItem -LiteralPath $desktop -Force -ErrorAction SilentlyContinue)) {
            if ($item.Extension -notin '.lnk', '.url') { continue }
            if ((Get-ShortcutProduct -Item $item -Shell $shell) -eq $product) {
                Write-Host "Ярлык уже есть: $($item.FullName)"
                return
            }
        }
    }
    $path = Join-Path $desktop ($Name + '.lnk')
    $link = $shell.CreateShortcut($path)
    $link.TargetPath = $Target
    $link.WorkingDirectory = $WorkDir
    $link.Description = $Name
    $link.Save()
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

    New-DesktopShortcut -Name 'Raw Accel' -Target $gui -WorkDir $dest

    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "Raw Accel $($release.tag_name) установлен."
    Write-Host 'Перезагрузите компьютер, чтобы драйвер заработал.'
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

function Publish-AppShortcuts {
    $apps = @(
        @{ Name = 'Spotify'; Path = (Join-Path $env:APPDATA 'Spotify\Spotify.exe') },
        @{ Name = 'Spotify'; Path = (Join-Path $env:LOCALAPPDATA 'Spotify\Spotify.exe') },
        @{ Name = 'Figma'; Path = (Join-Path $env:LOCALAPPDATA 'Figma\Figma.exe') },
        @{ Name = 'Figma'; Path = (Join-Path $env:ProgramFiles 'Figma\Figma.exe') },
        @{ Name = 'Raw Accel'; Path = (Join-Path $env:ProgramFiles 'RawAccel\rawaccel.exe') },
        @{ Name = 'Razer Synapse'; Path = (Join-Path $env:ProgramFiles 'Razer\RazerAppEngine\RazerAppEngine.exe') },
        @{ Name = 'Razer Synapse'; Path = (Join-Path ${env:ProgramFiles(x86)} 'Razer\RazerAppEngine\RazerAppEngine.exe') }
    )
    $figmaApps = Get-Item -Path (Join-Path $env:LOCALAPPDATA 'Figma\app-*\Figma.exe') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($figmaApps) {
        $apps += @{ Name = 'Figma'; Path = $figmaApps.FullName }
    }
    $graphite = Find-GraphiteClubExe
    if ($graphite) {
        $apps += @{ Name = 'Graphite Club'; Path = $graphite }
    }

    $done = @{}
    foreach ($app in $apps) {
        if (-not $app.Path -or -not (Test-Path -LiteralPath $app.Path)) { continue }
        if ($done.ContainsKey($app.Name)) { continue }
        $done[$app.Name] = $true
        New-DesktopShortcut -Name $app.Name -Target $app.Path -WorkDir (Split-Path -Parent $app.Path)
    }
}

function Resolve-Winget {
    $root = Join-Path $env:ProgramFiles 'WindowsApps'
    if (Test-Path -LiteralPath $root) {
        $hit = Get-ChildItem -LiteralPath $root -Filter 'winget.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'DesktopAppInstaller' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $alias) { return $alias }
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    return $null
}

function Invoke-Unelevated {
    param(
        [string]$File,
        [string]$Arguments
    )

    $id = [guid]::NewGuid().ToString('N')
    $wrapper = Join-Path $env:TEMP ("unelevated-" + $id + ".cmd")
    $codeFile = Join-Path $env:TEMP ("unelevated-" + $id + ".exit")
    $lines = @(
        '@echo off',
        ('"{0}" {1}' -f $File, $Arguments),
        ('echo %ERRORLEVEL% >"{0}"' -f $codeFile)
    )
    Set-Content -LiteralPath $wrapper -Value $lines -Encoding ASCII

    $runas = Join-Path $env:SystemRoot 'System32\runas.exe'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $runas
    $psi.Arguments = '/trustlevel:0x20000 "' + $wrapper + '"'
    $psi.UseShellExecute = $false
    $proc = [Diagnostics.Process]::Start($psi)
    $null = $proc.WaitForExit()
    if ($proc.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $codeFile)) {
        Remove-Item -LiteralPath $wrapper -Force -ErrorAction SilentlyContinue
        throw "Не удалось запустить установку без прав администратора. Код runas: $($proc.ExitCode)"
    }

    $deadline = (Get-Date).AddMinutes(40)
    while (-not (Test-Path -LiteralPath $codeFile) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
    }
    $code = 1
    if (Test-Path -LiteralPath $codeFile) {
        $text = (Get-Content -LiteralPath $codeFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        $parsed = 0
        if ([int]::TryParse(([string]$text).Trim(), [ref]$parsed)) { $code = $parsed }
    }
    Remove-Item -LiteralPath $wrapper, $codeFile -Force -ErrorAction SilentlyContinue
    return $code
}

function Install-UserApps {
    $winget = Resolve-Winget
    if (-not $winget) {
        Write-Host 'Не найден winget. Поставьте "Установщик приложений" из Microsoft Store.'
        Write-Host 'https://apps.microsoft.com/detail/9nblggh4nns1'
        exit 1
    }

    Write-Host "winget: $winget"
    $unelevated = Test-IsAdmin
    if ($unelevated) {
        Write-Host 'Окно с правами администратора. Spotify и Figma ставятся отдельно, без этих прав.'
    }

    $ids = @('Spotify.Spotify', 'Figma.Figma')
    $failed = 0
    $okCodes = @(0, 3010, -1978335189, -1978335135, -1978334967, -1978334965)
    foreach ($id in $ids) {
        Write-Host "Ставлю $id ..."
        $arg = "install --exact --id $id --accept-package-agreements --accept-source-agreements --disable-interactivity"
        if ($unelevated) {
            $code = Invoke-Unelevated -File $winget -Arguments $arg
        } else {
            & $winget install --exact --id $id --accept-package-agreements --accept-source-agreements --disable-interactivity
            $code = $LASTEXITCODE
        }
        if ($okCodes -contains [int]$code) {
            Write-Host "Готово: $id"
        } else {
            Write-Host "Не удалось поставить $id. Код: $code"
            $failed++
        }
    }
    if ($failed -gt 0) { exit 1 }
}

switch ($Action) {
    'Shortcuts' {
        Remove-DuplicateDesktopShortcuts
        New-SiteShortcut -Name 'SoundCloud' -Url 'https://soundcloud.com/' -IconName 'soundcloud.ico'
        New-SiteShortcut -Name 'GravaStar' -Url 'https://www.gravastar.com/' -IconName 'gravastar.ico'
        Publish-AppShortcuts
        Update-DesktopIcons
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
    'UserApps' {
        Install-UserApps
    }
    'ResolveWinget' {
        $winget = Resolve-Winget
        if (-not $winget) { exit 1 }
        Write-Output $winget
    }
}
