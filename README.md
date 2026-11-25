# AES-128-GCM + QR en DE10-Lite, con ESP32 e iPhone

Proyecto final de Sistemas Embebidos. Una FPGA **MAX 10 (DE10-Lite)** hace lo siguiente:

1. Cifra un mensaje de 16 bytes con **AES-128-GCM**.
2. Lo codifica en **Base64** (60 caracteres).
3. Genera un **código QR** (versión 4-M, 33×33) y lo muestra por **VGA**.

Un iPhone lee el QR y lo envía por Wi-Fi a una **ESP32**. La ESP32 se lo pasa por UART a la FPGA, que lo descifra y verifica la etiqueta GCM. El resultado aparece en el iPhone y en el navegador de la PC.

```
PC --Wi-Fi--> ESP32 --UART 'E'--> FPGA: cifra, QR por VGA, contesta 'C'
iPhone lee el QR --Wi-Fi--> ESP32 --UART 'D'--> FPGA: descifra, contesta 'P'
ESP32 --Wi-Fi--> PC / iPhone muestran el resultado
```

## Carpetas

| Carpeta | Contenido |
|---|---|
| `quartus/` | 17 archivos Verilog, `de10lite_top.sdc` y `pines_de10lite.tcl`. Entidad superior: `de10lite_top`. |
| `simulacion/` | Bancos de prueba (Icarus Verilog / Active-HDL) y vectores OpenSSL. No van a Quartus. |
| `esp32/` | Sketch de Arduino para ESP32 WROOM-32 y script de carga. |
| `documentacion/` | Guías (LEEME), captura simulada del VGA. |

Empieza por `LEEME.txt` y `documentacion/LEEME_top.txt`.

## Seguridad: solo es una demostración

- La clave AES está **fija en el código y es pública** (`000102…0f`).
- El contador del nonce vuelve a 0 al reiniciar la placa, así que **los nonces se repiten** entre encendidos.
- La clave del Wi-Fi de la ESP32 (`fpga1234`) también es de prueba.

No uses este diseño para proteger datos reales.

## Licencias

`quartus/qr_matrix.v` adapta código de la biblioteca QR de Project Nayuki (licencia MIT). Ver `quartus/LICENSE_qr_reference.txt`.
