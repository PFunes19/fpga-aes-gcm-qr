# Compila y carga esp32_fpga_qr a una ESP32 (WROOM-32 / "ESP32 Dev Module").
# Uso (PowerShell, desde esta carpeta):
#   powershell -ExecutionPolicy Bypass -File .\cargar_esp32.ps1            (detecta el puerto)
#   powershell -ExecutionPolicy Bypass -File .\cargar_esp32.ps1 -Puerto COM6
# Si aparece "Connecting....." y falla: mantener presionado BOOT mientras
# conecta, soltarlo cuando avance el porcentaje y al final presionar EN.

param([string]$Puerto = "")

$cli    = "C:\Program Files\Arduino CLI\arduino-cli.exe"
$sketch = Join-Path $PSScriptRoot "esp32_fpga_qr"
$fqbn   = "esp32:esp32:esp32"

if (-not (Test-Path $cli)) {
    Write-Host "No se encontro arduino-cli en $cli. Usar Arduino IDE (ver LEEME_esp32.txt)."
    exit 1
}

if ($Puerto -eq "") {
    $puertos = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
    if ($puertos.Count -eq 0) {
        Write-Host "No hay ningun puerto COM. Conecta la ESP32 (cable USB de datos) o instala el driver CP210x/CH340."
        exit 1
    }
    if (@($puertos).Count -gt 1) {
        Write-Host "Hay varios puertos: $($puertos -join ', '). Indica uno con -Puerto COMx."
        exit 1
    }
    $Puerto = @($puertos)[0]
}

Write-Host "Compilando y cargando en $Puerto ..."
& $cli compile --upload -p $Puerto --fqbn $fqbn $sketch
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "FALLO la carga. Reintenta manteniendo presionado BOOT durante 'Connecting...'."
    exit 1
}
Write-Host ""
Write-Host "Listo. Presiona EN en la ESP32. Debe aparecer la red Wi-Fi FPGA-QR (clave fpga1234)."
