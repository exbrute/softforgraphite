@echo off
setlocal EnableExtensions
cd /d "%~dp0"
chcp 65001 >nul
title Установка программ

rem Дважды щелкните этот файл.
rem Рядом должны лежать setup.ps1 и папка extras.
rem Свои установщики: положите .exe в extras и запустите файл ещё раз.
rem После установки Spotify, Figma, Raw Accel, Razer, Graphite Club и оба сайта
rem прописываются в автозагрузку текущего пользователя.

if /I "%~1"=="--elevated" goto Elevated

set "FAILS=0"
set "LOG=%~dp0install-log.txt"
> "%LOG%" echo ==== %DATE% %TIME% ====

echo.
echo Папка: %~dp0
echo Запускайте файл обычным двойным щелчком, не от имени администратора.
echo Права администратора скрипт запросит сам, когда дойдёт до драйвера.
echo.

net session >nul 2>&1
if not errorlevel 1 (
    echo Файл уже запущен от имени администратора.
    echo Spotify и Figma так поставить нельзя.
    echo Сейчас ставятся только Visual C++, Raw Accel и Razer Synapse 4.
    echo Чтобы поставить остальное, закройте окно и откройте install.bat двойным щелчком.
    echo.
    goto Elevated
)

call :ResolveWinget
if errorlevel 1 (
    echo Не найден winget.
    echo Поставьте "Установщик приложений" из Microsoft Store и запустите файл снова:
    echo https://apps.microsoft.com/detail/9nblggh4nns1
    echo Spotify и Figma будут пропущены.
    >> "%LOG%" echo FAIL winget missing
    set /a FAILS+=1
    goto UserShortcuts
)

echo Обновляю список программ winget...
"%WINGET%" source update --disable-interactivity
if errorlevel 1 (
    echo Список winget не обновился. Пробую ставить дальше.
    >> "%LOG%" echo WARN winget source update
)

echo.
echo [Spotify]
call :Winget "Spotify.Spotify"

echo.
echo [Figma]
call :Winget "Figma.Figma"

:UserShortcuts
echo.
echo [Ярлыки на рабочем столе]
call :NeedSetup
if errorlevel 1 (
    set /a FAILS+=1
    goto UserExtras
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Action Shortcuts
if errorlevel 1 (
    echo Не удалось создать ярлыки SoundCloud и GravaStar.
    >> "%LOG%" echo FAIL shortcuts
    set /a FAILS+=1
) else (
    echo На рабочем столе: SoundCloud и GravaStar.
    >> "%LOG%" echo OK shortcuts
)

:UserExtras
echo.
echo [Свои программы из папки extras]
if not exist "%~dp0extras\*.exe" (
    echo В папке extras пока нет exe.
    echo Когда файлы будут готовы, положите их туда и запустите install.bat снова.
    >> "%LOG%" echo SKIP extras empty
    goto Elevate
)

for %%F in ("%~dp0extras\*.exe") do (
    echo.
    echo Запуск %%~nxF
    >> "%LOG%" echo RUN %%~nxF
    echo %%~nxF | findstr /I /B "Graphite-Club-Setup" >nul
    if not errorlevel 1 (
        start /wait "" "%%~fF" /S
    ) else (
        start /wait "" "%%~fF"
    )
    if errorlevel 1 (
        echo %%~nxF завершился с ошибкой.
        >> "%LOG%" echo FAIL %%~nxF
        set /a FAILS+=1
    ) else (
        echo Готово: %%~nxF
        >> "%LOG%" echo OK %%~nxF
    )
)

:Elevate
call :EnableAutostart
echo.
echo Дальше ставятся Visual C++, Raw Accel и Razer Synapse 4.
echo Подтвердите запрос администратора в окне Windows.
>> "%LOG%" echo INFO requesting admin
call :NeedSetup
if errorlevel 1 (
    set /a FAILS+=1
    goto Summary
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Action Elevate
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo Часть с правами администратора завершилась с кодом %RC%.
    >> "%LOG%" echo FAIL elevated code %RC%
    set /a FAILS+=RC
) else (
    >> "%LOG%" echo OK elevated
)

:Summary
echo.
echo ----------------------------------------
if "%FAILS%"=="0" (
    echo Готово, без ошибок.
    >> "%LOG%" echo RESULT ok
) else (
    echo Готово, но есть ошибки: %FAILS%.
    echo Лог: %LOG%
    >> "%LOG%" echo RESULT fails %FAILS%
)
echo.
echo Если Raw Accel установился, перезагрузите компьютер, чтобы драйвер заработал.
echo При входе в Windows сами запустятся Spotify, Figma, Graphite Club, Raw Accel, Razer Synapse, SoundCloud и GravaStar.
echo.
pause
endlocal & exit /b %FAILS%

:Elevated
set "FAILS=0"
set "LOG=%~dp0install-log.txt"
>> "%LOG%" echo ==== elevated %DATE% %TIME% ====

net session >nul 2>&1
if errorlevel 1 (
    echo Права администратора не получены.
    >> "%LOG%" echo FAIL not admin
    pause
    endlocal & exit /b 1
)

call :ResolveWinget
if errorlevel 1 (
    echo winget не найден. Visual C++ и Razer Synapse 4 пропущены.
    >> "%LOG%" echo FAIL winget missing elevated
    set /a FAILS+=1
    goto ElevatedRaw
)

echo.
echo [Visual C++] Нужен для Raw Accel
call :Winget "Microsoft.VCRedist.2015+.x64"

echo.
echo [Razer Synapse 4]
call :Winget "RazerInc.RazerInstaller.Synapse4"

:ElevatedRaw
echo.
echo [Raw Accel]
call :NeedSetup
if errorlevel 1 (
    set /a FAILS+=1
    goto ElevatedDone
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Action RawAccel
if errorlevel 1 (
    echo Raw Accel не установлен.
    >> "%LOG%" echo FAIL RawAccel
    set /a FAILS+=1
) else (
    echo Raw Accel установлен. На рабочем столе появился ярлык Raw Accel.
    >> "%LOG%" echo OK RawAccel
)

:ElevatedDone
call :EnableAutostart full
echo.
if "%FAILS%"=="0" (
    echo Эта часть прошла без ошибок.
    >> "%LOG%" echo RESULT elevated ok
) else (
    echo Ошибок в этой части: %FAILS%.
    echo Лог: %LOG%
    >> "%LOG%" echo RESULT elevated fails %FAILS%
)
echo.
echo Нажмите любую клавишу, чтобы закрыть это окно.
pause
endlocal & exit /b %FAILS%

:EnableAutostart
echo.
echo [Автозагрузка]
call :NeedSetup
if errorlevel 1 (
    set /a FAILS+=1
    exit /b 0
)
if /I "%~1"=="full" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Action EnableAutostart -IncludeSystemApps
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Action EnableAutostart
)
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo Не удалось прописать автозагрузку.
    >> "%LOG%" echo FAIL autostart code %RC%
    set /a FAILS+=1
) else (
    echo Автозагрузка настроена.
    >> "%LOG%" echo OK autostart
)
exit /b 0

:NeedSetup
if exist "%~dp0setup.ps1" exit /b 0
echo Рядом с install.bat нет файла setup.ps1. Эти два файла нужно держать вместе.
>> "%LOG%" echo FAIL setup.ps1 missing
exit /b 1

:ResolveWinget
set "WINGET="
if exist "%LocalAppData%\Microsoft\WindowsApps\winget.exe" (
    set "WINGET=%LocalAppData%\Microsoft\WindowsApps\winget.exe"
    exit /b 0
)
for /f "delims=" %%I in ('powershell -NoProfile -Command "(Get-Command winget -ErrorAction SilentlyContinue^).Source"') do (
    if not defined WINGET set "WINGET=%%I"
)
if not defined WINGET exit /b 1
exit /b 0

:Winget
set "PKG=%~1"
echo Ставлю %PKG% ...
"%WINGET%" install --exact --id "%PKG%" --accept-package-agreements --accept-source-agreements --disable-interactivity
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" goto WingetOk
if "%RC%"=="3010" goto WingetReboot
if "%RC%"=="-1978335189" goto WingetAlready
if "%RC%"=="-1978335135" goto WingetAlready
if "%RC%"=="-1978334967" goto WingetReboot
if "%RC%"=="-1978334965" goto WingetReboot
echo Не удалось поставить %PKG%. Код winget: %RC%. Иду дальше.
>> "%LOG%" echo FAIL %PKG% code %RC%
set /a FAILS+=1
exit /b 0

:WingetOk
echo Готово: %PKG%
>> "%LOG%" echo OK %PKG%
exit /b 0

:WingetAlready
echo Уже стоит: %PKG%
>> "%LOG%" echo SKIP %PKG% code %RC%
exit /b 0

:WingetReboot
echo Готово: %PKG%. Может понадобиться перезагрузка.
>> "%LOG%" echo OK %PKG% reboot code %RC%
exit /b 0
