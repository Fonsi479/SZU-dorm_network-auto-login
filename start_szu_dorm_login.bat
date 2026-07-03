@echo off
chcp 65001 >nul
setlocal EnableExtensions

set "PROJECT_ROOT=%~dp0"
cd /d "%PROJECT_ROOT%"

set "PYTHONPATH=%PROJECT_ROOT%;%PYTHONPATH%"
set "SZU_NETLOGIN_HOME=%PROJECT_ROOT%"

set "PYTHON_EXE=%PROJECT_ROOT%.venv-szu-dorm-login\Scripts\python.exe"
set "PYTHONW_EXE=%PROJECT_ROOT%.venv-szu-dorm-login\Scripts\pythonw.exe"
if exist "%PYTHON_EXE%" goto :run_app

where pyw >nul 2>nul
if not errorlevel 1 (
  start "" pyw -3 apps\windows_desktop\szu_windows_desktop.py
  exit /b 0
)

where pythonw >nul 2>nul
if not errorlevel 1 (
  start "" pythonw apps\windows_desktop\szu_windows_desktop.py
  exit /b 0
)

where py >nul 2>nul
if not errorlevel 1 (
  py -3 apps\windows_desktop\szu_windows_desktop.py
  exit /b %ERRORLEVEL%
)

where python >nul 2>nul
if not errorlevel 1 (
  python apps\windows_desktop\szu_windows_desktop.py
  exit /b %ERRORLEVEL%
)

echo Cannot find Python. Please double-click one_click_install_and_run.bat first.
pause
exit /b 1

:run_app
if exist "%PYTHONW_EXE%" (
  start "" "%PYTHONW_EXE%" "%PROJECT_ROOT%apps\windows_desktop\szu_windows_desktop.py"
  exit /b 0
)

start "" "%PYTHON_EXE%" "%PROJECT_ROOT%apps\windows_desktop\szu_windows_desktop.py"
exit /b 0
