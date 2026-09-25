@echo off
setlocal

set "PYTHON=C:\Users\juras\anaconda3\envs\tinysd\python.exe"
set "SCRIPT_DIR=%~dp0"

cd /d "%SCRIPT_DIR%"

if not exist "%PYTHON%" (
    echo [ERROR] Python env "tinysd" non trovato in:
    echo   %PYTHON%
    echo Controlla che l'ambiente conda "tinysd" esista ancora su questa macchina.
    pause
    exit /b 1
)

if not exist "%SCRIPT_DIR%wgsl_shm.py" (
    echo [ERROR] wgsl_shm.py non trovato in %SCRIPT_DIR%
    pause
    exit /b 1
)

echo [wgsl-shm] output: NDI + Spout, nome sender "wgsl-shm"
echo [wgsl-shm] pannello di controllo: http://127.0.0.1:54321/
echo.

"%PYTHON%" "%SCRIPT_DIR%wgsl_shm.py" --out ndi spout --ndi-name "wgsl-shm" --spout-name "wgsl-shm"

echo.
echo [wgsl-shm] uscito (exit code %ERRORLEVEL%).
pause
