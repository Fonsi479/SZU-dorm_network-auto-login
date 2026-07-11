@echo off
chcp 65001 >nul
setlocal EnableExtensions

set "PROJECT_ROOT=%~dp0"
cd /d "%PROJECT_ROOT%"
set "PYTHON_VERSION=3.12.10"
set "PYTHON_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/python/%PYTHON_VERSION%"
set "PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple"
set "PIP_TRUSTED_HOST=pypi.tuna.tsinghua.edu.cn"
set "PIP_DISABLE_PIP_VERSION_CHECK=1"

echo.
echo [SZU Dorm Login] One-click install and launch
echo.

echo [1/5] Checking Python 3.10+...
call :find_python
if not defined PYTHON_EXE (
  echo Python was not found. Installing Python %PYTHON_VERSION% from Tsinghua mirror...
  call :install_python_from_mirror
  timeout /t 2 /nobreak >nul
  call :find_python
)

if not defined PYTHON_EXE (
  call :ensure_winget
  if not errorlevel 1 (
    echo Tsinghua mirror install did not provide Python. Trying winget fallback...
    winget install --id Python.Python.3.12 -e --silent --accept-package-agreements --accept-source-agreements
    timeout /t 2 /nobreak >nul
    call :find_python
  )
)

if not defined PYTHON_EXE (
  echo.
  echo Python is still not available.
  echo Close this window and double-click this script again.
  echo If it still fails, install Python 3.10+ manually and check "Add python.exe to PATH".
  goto :failed
)

echo Using Python: %PYTHON_EXE%
"%PYTHON_EXE%" --version
if errorlevel 1 goto :failed

echo.
echo [2/5] Creating local runtime environment...
set "VENV_DIR=%PROJECT_ROOT%.venv-szu-dorm-login"
set "VENV_PYTHON=%VENV_DIR%\Scripts\python.exe"
set "VENV_PYTHONW=%VENV_DIR%\Scripts\pythonw.exe"
if not exist "%VENV_PYTHON%" (
  "%PYTHON_EXE%" -m venv "%VENV_DIR%"
  if errorlevel 1 goto :failed
)

echo.
echo [3/5] Installing app dependencies...
"%VENV_PYTHON%" -m pip install --index-url "%PIP_INDEX_URL%" --trusted-host "%PIP_TRUSTED_HOST%" --upgrade pip
if errorlevel 1 goto :failed
"%VENV_PYTHON%" -m pip install --index-url "%PIP_INDEX_URL%" --trusted-host "%PIP_TRUSTED_HOST%" -r requirements.txt
if errorlevel 1 goto :failed

echo.
echo [4/5] Creating desktop shortcut...
call :create_shortcut
if errorlevel 1 goto :failed

echo.
echo [5/5] Launching SZU Dorm Login...
call start_szu_dorm_login.bat
exit /b %ERRORLEVEL%

:ensure_winget
where winget >nul 2>nul
if not errorlevel 1 exit /b 0
echo winget was not found. Please use Windows 10/11 with App Installer enabled.
exit /b 1

:install_python_from_mirror
call :select_python_installer
set "PYTHON_INSTALLER_PATH=%TEMP%\%PYTHON_INSTALLER%"
set "PYTHON_INSTALLER_URL=%PYTHON_MIRROR%/%PYTHON_INSTALLER%"
echo Downloading: %PYTHON_INSTALLER_URL%
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri $env:PYTHON_INSTALLER_URL -OutFile $env:PYTHON_INSTALLER_PATH"
if errorlevel 1 exit /b 1
echo Installing: %PYTHON_INSTALLER%
start /wait "" "%PYTHON_INSTALLER_PATH%" /quiet InstallAllUsers=0 PrependPath=1 Include_launcher=1 Include_pip=1 Include_test=0 SimpleInstall=1
exit /b 0

:select_python_installer
set "PYTHON_INSTALLER=python-%PYTHON_VERSION%.exe"
if /i "%PROCESSOR_ARCHITECTURE%"=="AMD64" set "PYTHON_INSTALLER=python-%PYTHON_VERSION%-amd64.exe"
if /i "%PROCESSOR_ARCHITEW6432%"=="AMD64" set "PYTHON_INSTALLER=python-%PYTHON_VERSION%-amd64.exe"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "PYTHON_INSTALLER=python-%PYTHON_VERSION%-arm64.exe"
if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "PYTHON_INSTALLER=python-%PYTHON_VERSION%-arm64.exe"
exit /b 0

:find_python
set "PYTHON_EXE="
for /f "delims=" %%P in ('py -3 -c "import sys; print(sys.executable)" 2^>nul') do call :test_python "%%P"
call :test_python "%LocalAppData%\Programs\Python\Python312\python.exe"
call :test_python "%LocalAppData%\Programs\Python\Python312-arm64\python.exe"
call :test_python "%LocalAppData%\Programs\Python\Python311\python.exe"
call :test_python "%LocalAppData%\Programs\Python\Python311-arm64\python.exe"
call :test_python "%LocalAppData%\Programs\Python\Python310\python.exe"
call :test_python "%LocalAppData%\Programs\Python\Python310-arm64\python.exe"
call :test_python "%ProgramFiles%\Python312\python.exe"
call :test_python "%ProgramFiles%\Python312-arm64\python.exe"
call :test_python "%ProgramFiles%\Python311\python.exe"
call :test_python "%ProgramFiles%\Python311-arm64\python.exe"
call :test_python "%ProgramFiles%\Python310\python.exe"
call :test_python "%ProgramFiles%\Python310-arm64\python.exe"
for /d %%D in ("%LocalAppData%\Programs\Python\Python*") do call :test_python "%%~fD\python.exe"
for /d %%D in ("%ProgramFiles%\Python*") do call :test_python "%%~fD\python.exe"
for /d %%D in ("%ProgramFiles(x86)%\Python*") do call :test_python "%%~fD\python.exe"
for /f "delims=" %%P in ('where python 2^>nul') do call :test_python "%%P"
exit /b 0

:test_python
if defined PYTHON_EXE exit /b 0
if not exist "%~1" exit /b 0
"%~1" -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)" >nul 2>nul
if not errorlevel 1 set "PYTHON_EXE=%~1"
exit /b 0

:create_shortcut
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$root=$env:PROJECT_ROOT; $pythonw=$env:VENV_PYTHONW; $script=Join-Path $root 'apps\windows_desktop\szu_windows_desktop.py'; if(-not (Test-Path -LiteralPath $pythonw)){ Write-Error 'pythonw.exe was not found'; exit 2 }; $w=New-Object -ComObject WScript.Shell; $p=[IO.Path]::Combine([Environment]::GetFolderPath('Desktop'),'SZU Dorm Login.lnk'); $s=$w.CreateShortcut($p); $s.TargetPath=$pythonw; $s.Arguments='\"' + $script + '\"'; $s.WorkingDirectory=$root; $s.WindowStyle=7; $s.Save(); if(-not (Test-Path -LiteralPath $p)){ Write-Error 'Desktop shortcut was not created'; exit 3 }" >nul 2>nul
exit /b %ERRORLEVEL%

:failed
echo.
echo Install failed. Take a screenshot of this window and send it back to Codex.
pause
exit /b 1
