# 0. Arquitectura general (cómo presentarlo en 2 minutos)

## La idea en una frase

La FPGA **cifra** un mensaje de 16 bytes con AES-128-GCM, lo convierte en un **código QR** y lo muestra por **VGA**. El celular lee el QR y lo manda de regreso a la FPGA (por medio de la ESP32), y la FPGA lo **descifra y verifica** que nadie lo haya alterado.

## Diagrama de bloques

```
                       de10lite_top (25 MHz)
   KEY1 ──► antirrebote ─┐
   SW   ──► "DE10-Lite SW=xyz" ─┐
                         ▼      ▼
 UART_RX ─► uart_command_port ─► FSM de comandos ─┬─► crypto_qr_controller ─► vga_qr_display ─► VGA
 UART_TX ◄─      (uart_rx,        (IDLE/ENC/      │     aes_gcm → base64_encode → qr_generator
                  uart_tx)         DEC/RESP)      │
                                                  └─► crypto_decrypt_controller
                                                        base64_decode → aes_gcm (descifrar)
                                   LEDR, HEX0..HEX5 ◄── estado
```

## Jerarquía de archivos (quién usa a quién)

| Módulo | Qué hace | Lo usa |
|---|---|---|
| `de10lite_top` | Pines de la placa, reloj, reset, botones, FSM, LEDs y displays | (nivel superior) |
| `uart_command_port` | Arma las tramas `E`/`D` que llegan y envía las respuestas `C`/`P` | top |
| `uart_rx`, `uart_tx` | Reciben y envían **un byte** serie 8N1 | uart_command_port |
| `crypto_qr_controller` | Cifra → Base64 → QR | top |
| `crypto_decrypt_controller` | Base64 → descifra → verifica etiqueta | top |
| `aes_gcm` | El modo GCM: contador (CTR) + autenticación (GHASH) | los dos controladores |
| `aes128_core` | El cifrador de bloque AES-128 (10 rondas) | aes_gcm |
| `ghash`, `gf128_mult` | Multiplicación en GF(2^128) para la etiqueta | aes_gcm |
| `base64_encode`, `base64_decode` | 44 bytes ⇄ 60 caracteres de texto | controladores |
| `qr_generator` | Encadena las 3 etapas del QR | crypto_qr_controller |
| `qr_data_encode` | Arma los bits de datos (modo byte) | qr_generator |
| `qr_rs_encoder` | Corrección de errores Reed-Solomon | qr_generator |
| `qr_matrix` | Dibuja la matriz 33×33 y elige la máscara | qr_generator |
| `vga_qr_display` | Genera la señal VGA 640×480 y pinta el QR | top |

## Por qué cada decisión (preguntas típicas)

- **¿Por qué AES-GCM y no solo AES?**
  - AES solo oculta el mensaje, pero no detecta si alguien lo modificó.
  - GCM agrega una **etiqueta (tag) de 16 bytes**. Si se cambia un solo bit del QR, la etiqueta no coincide y la FPGA lo rechaza (LEDR3 / respuesta `T`).
- **¿Qué es el nonce?**
  - Es un número de 12 bytes que **nunca debe repetirse con la misma clave**. Aquí es `de1011fe00000000` más un contador.
  - Va dentro del QR porque el que descifra lo necesita.
  - Limitación honesta: el contador vuelve a 0 al apagar la placa, así que es solo una demostración.
- **¿Por qué Base64?**
  - El paquete (nonce 12 + cifrado 16 + etiqueta 16 = 44 bytes) es binario, con bytes que no son letras.
  - Base64 lo convierte en 60 caracteres imprimibles. Así el celular lo lee como texto normal y se puede mandar por web o UART sin problemas.
- **¿Por qué QR versión 4, nivel M?**
  - V4 es una matriz de 33×33 módulos.
  - Con nivel M (recupera ~15 % de daño) caben 62 bytes en modo byte. Los 60 caracteres sí caben.
- **¿Por qué la ESP32?**
  - La FPGA no tiene Wi-Fi. La ESP32 hace de puente: Wi-Fi/HTTP de un lado y UART del otro.
- **¿Por qué 25 MHz y no 50 MHz?**
  - Quartus midió que el camino combinacional más largo tarda ~29 ns.
  - A 50 MHz solo hay 20 ns por ciclo. A 25 MHz hay 40 ns, y sí alcanza.
  - Además, el VGA 640×480 necesita justo 25 MHz.
- **¿Cuántos recursos usa?**
  - Cerca del 77 % de los elementos lógicos de la MAX 10 (unos 38 mil de 49,760). Ese dato viene de la primera compilación de Quartus.
  - Lo que más ocupa es AES + GHASH + QR.

## Orden recomendado para estudiar

1. `de10lite_top` (01_de10lite_top.md), que conecta todo.
2. `uart_rx` / `uart_tx` / `uart_command_port`, que ya conoces de la práctica.
3. `vga_qr_display`, que es fácil de explicar con dibujos.
4. `crypto_qr_controller` y `crypto_decrypt_controller`, que son máquinas de estados que llaman a los bloques.
5. `base64_*`.
6. `aes_gcm` / `aes128_core` / `ghash`. Explicarlos a nivel de bloque, no bit por bit.
7. QR (`qr_*`). Explicarlo a nivel de bloque. Aclarar que `qr_matrix` adapta código MIT de Nayuki (licencia en `LICENSE_qr_reference.txt`).
