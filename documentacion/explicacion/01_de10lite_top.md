# 1. `de10lite_top.v`, explicado línea por línea

Los números de línea son los del archivo `quartus\de10lite_top.v`. Ábrelo al lado de esta guía.

---

## Líneas 1–33: encabezado

- **L1 `` `timescale 1ns/1ps ``**: solo sirve para simulación. Dice que `#1` = 1 ns, con precisión de 1 ps. Quartus lo ignora.
- **L3–32**: comentarios con el flujo completo, el protocolo UART y el significado de botones y LEDs. Es la "documentación" del módulo.

## Líneas 34–41: parámetros

Son constantes que se pueden cambiar al instanciar el módulo, sin editar el código.

| Parámetro | Valor | Para qué |
|---|---|---|
| `DEMO_KEY` | `0x000102…0f` | Clave AES de 128 bits. Fija y pública: es de prueba. |
| `NONCE_PREFIX` | `0xde1011fe00000000` | Los primeros 8 bytes del nonce (el nonce mide 12). |
| `DEBOUNCE_CYCLES` | 250000 | 250000 ciclos / 25 MHz = **10 ms** de antirrebote. |
| `POR_BITS` | 20 | Tamaño del contador de reset al encender: 2^20 / 25 MHz ≈ **42 ms**. |
| `UART_BAUD` | 115200 | Velocidad serie. |
| `UART_TIMEOUT` | 1250000 | 1250000 / 25 MHz = **50 ms**. Si una trama se queda a medias, se descarta. |

> El profe puede preguntar: *"¿por qué parámetros y no números directos?"*
> Respuesta: para el testbench. En simulación se usan valores pequeños para que no tarde horas. Por ejemplo, no hay que simular 10 ms de antirrebote.

## Líneas 42–62: puertos (los pines de la placa)

- Los nombres (`MAX10_CLK1_50`, `KEY`, `SW`, `LEDR`, `HEX0`…) son los del manual de la DE10-Lite. En el Pin Planner se asignan con esos nombres.
- `KEY` es **activo en bajo**: suelto = 1, presionado = 0.
- `HEXn[7:0]`: 7 segmentos + punto, también activos en bajo (0 = encendido).
- VGA: 4 bits por color (la DE10-Lite tiene un DAC de resistencias de 4 bits) + sincronías H y V.
- `UART_RX` / `UART_TX`: dos pines del GPIO conectados a la ESP32, cruzados (TX de uno → RX del otro).

## Líneas 70–74: divisor de reloj (50 → 25 MHz)

```verilog
localparam integer CLK_HZ = 25000000;
reg clk_div = 1'b0;
always @(posedge MAX10_CLK1_50)
    clk_div <= ~clk_div;
wire clk = clk_div;
```

- `localparam`: constante interna que no se puede cambiar desde fuera. Se le pasa al UART para que calcule los ciclos por bit.
- Es un **flip-flop tipo T**: en cada flanco de subida de 50 MHz se invierte. Un periodo completo de `clk_div` dura 2 periodos de 50 MHz, o sea, 25 MHz.
- `= 1'b0` es el valor inicial. En la MAX 10 los registros arrancan con ese valor al configurarse.
- **Todo** lo demás del diseño usa `clk` (25 MHz).
- En el `.sdc`, `create_generated_clock -divide_by 2` le dice al analizador de tiempos que este registro es un reloj de 25 MHz.
- Quartus lo detecta y lo pasa a la **red global de reloj** (mensaje "Automatically promoted node clk_div").

> Pregunta probable: *"¿por qué no un PLL?"*
> Un PLL (IP ALTPLL) es la forma "formal". Dividir con un registro es más simple, funciona bien a esta frecuencia y el `.sdc` lo declara correctamente.

## Líneas 80–91: reset

```verilog
reg [POR_BITS-1:0] por_cnt = {POR_BITS{1'b0}};
wire por_done = &por_cnt;
always @(posedge clk)
    if (!por_done) por_cnt <= por_cnt + 1'b1;
```

- **POR = Power-On Reset.** Al encender, `por_cnt` vale 0 y cuenta hasta que todos sus bits son 1.
- `&por_cnt` es un **AND de reducción**: da 1 solo cuando todos los bits valen 1. Entonces `por_done = 1` y el contador se detiene.
- Resultado: el sistema queda en reset unos 42 ms al encender, sin tener que presionar nada.
- `{POR_BITS{1'b0}}` es una replicación: 20 ceros.

```verilog
wire reset_req = ~por_done | ~KEY[0];
```

- Hay que resetear si todavía no termina el POR **o** si se presiona KEY0 (activo en bajo, por eso `~`).

```verilog
reg [1:0] rst_sync = 2'b11;
always @(posedge clk or posedge reset_req)
    if (reset_req) rst_sync <= 2'b11;
    else           rst_sync <= {rst_sync[0], 1'b0};
wire reset = rst_sync[1];
```

- Es un **sincronizador de reset: aserción asíncrona, liberación síncrona**.
  - Al presionar KEY0, `rst_sync` se pone en `11` **al instante**, sin esperar un reloj, porque `reset_req` está en la lista de sensibilidad.
  - Al soltar, entran ceros por la derecha, uno por ciclo: `11 → 10 → 00`. El reset baja **dos flancos después y siempre alineado con el reloj**.
- **¿Por qué?** KEY0 es asíncrono. Si el reset bajara justo cerca de un flanco, algunos flip-flops saldrían del reset en un ciclo y otros en el siguiente (violación de *recovery/removal*, metaestabilidad). Con esto, todos salen juntos.

## Líneas 96–119: KEY1, sincronizador + antirrebote + detector de flanco

```verilog
key1_sync <= {key1_sync[0], ~KEY[1]};
```

- `~KEY[1]`: se invierte para que 1 = presionado.
- `key1_sync` son **2 flip-flops en cadena (sincronizador)**. Si el primero queda metaestable, tiene un ciclo completo para estabilizarse antes de que el segundo lo lea.

```verilog
if (key1_sync[1] == key1_stable)
    deb_cnt <= 19'd0;
else if (deb_cnt == DEBOUNCE_CYCLES-1) begin
    deb_cnt     <= 19'd0;
    key1_stable <= key1_sync[1];
end else
    deb_cnt <= deb_cnt + 19'd1;
```

- **Antirrebote por tiempo.** `key1_stable` es el valor "aceptado" del botón.
  - Si la entrada es igual al valor aceptado, el contador se reinicia (no hay cambio).
  - Si es distinta, se cuenta. Si se mantiene distinta **10 ms seguidos**, se acepta el nuevo valor.
  - Un rebote (pulsos de microsegundos) reinicia el contador, así que nunca llega a 250000.
- `deb_cnt` es de 19 bits porque 2^19 = 524288 > 250000.

```verilog
key1_prev <= key1_stable;
...
wire key_pulse = key1_stable & ~key1_prev;
```

- **Detector de flanco de subida.** `key1_prev` es el valor del ciclo anterior.
- `key_pulse` vale 1 **un solo ciclo**: cuando ahora está presionado y antes no. Así, mantener el botón presionado cifra una sola vez.

## Líneas 124–138: mensaje de los interruptores

```verilog
sw_s1 <= SW;
sw_s2 <= sw_s1;
```

- Los interruptores también son asíncronos, así que llevan el mismo sincronizador de 2 flip-flops.

```verilog
function [7:0] hex_ascii;
    input [3:0] d;
    hex_ascii = (d < 4'd10) ? (8'h30 + {4'd0, d}) : (8'h41 + {4'd0, d} - 8'd10);
endfunction
```

- Convierte un dígito de 4 bits en su carácter ASCII.
  - 0–9 → `'0'` (0x30) + d.
  - 10–15 → `'A'` (0x41) + (d − 10).
- Una `function` en Verilog es **lógica combinacional**: no tiene reloj.

```verilog
wire [127:0] sw_message = {"DE10-Lite SW=", hex_ascii(...), hex_ascii(...), hex_ascii(...)};
```

- En Verilog, un texto entre comillas es un vector de 8 bits por letra.
  - `"DE10-Lite SW="` tiene 13 letras = 104 bits.
  - Más 3 dígitos × 8 = 24 bits. Total **128 bits = 16 bytes = un bloque AES**.
- Los 10 interruptores dan 3 dígitos hex. El primero solo usa SW[9:8], por eso se rellena con `2'b00`.
- Ejemplo: SW = `10_1010_0101` da `"DE10-Lite SW=2A5"`.

## Líneas 143–166: puerto UART

```verilog
uart_rx_s1 <= UART_RX;
uart_rx_s2 <= uart_rx_s1;
```

- Dos registros más en la entrada. `uart_rx` ya trae su propio sincronizador. Estos solo ayudan a que el primer registro quede cerca del pin, y son inofensivos.

- **L149–156: las señales entre el top y el puerto UART** (es un "contrato"):
  - `cmd_valid`: hay una trama completa lista. Se queda en 1 hasta que el top contesta con `cmd_ack`.
  - `cmd_type`: el primer byte, `"E"` o `"D"`.
  - `cmd_payload[479:0]`: hasta 60 bytes de datos. Para `'E'` los 16 bytes quedan en `[127:0]`, con el primero en `[127:120]`.
  - `resp_start` / `resp_len` / `resp_data`: el top pide "envía estos `resp_len` bytes". Se envían desde los bits más altos (MSB primero).
  - `resp_busy`: el puerto está transmitiendo.
- **L158–166: instancia `puerto`.**
  - `#(...)` pasa parámetros. Con `CLK_FREQ` y `BAUD_RATE` el UART calcula 25e6 / 115200 ≈ 217 ciclos por bit.
  - `.clk(clk)` conecta el puerto interno `clk` al cable `clk` del top (conexión por nombre).

## Líneas 171–177: estados y decodificación de comandos

```verilog
localparam [1:0] S_IDLE = 2'd0, S_ENC = 2'd1, S_DEC = 2'd2, S_RESP = 2'd3;
```

- 4 estados en 2 bits:
  - **IDLE**: espera.
  - **ENC**: cifrando.
  - **DEC**: descifrando.
  - **RESP**: enviando la respuesta por UART.

```verilog
wire uart_enc = (state == S_IDLE) && cmd_valid && (cmd_type == "E");
wire uart_dec = (state == S_IDLE) && cmd_valid && (cmd_type == "D");
wire key_enc  = (state == S_IDLE) && !cmd_valid && key_pulse;
wire enc_start = uart_enc || key_enc;
```

- Son señales combinacionales que dicen "en este ciclo arranca algo".
- Solo pueden valer 1 en IDLE, así que **una operación a la vez**.
- `key_enc` exige `!cmd_valid`: si llegan al mismo tiempo un comando UART y KEY1, **gana el UART**.
- El cifrado puede arrancar por UART o por KEY1, por eso el OR.

## Líneas 180–194: cifrado (crypto_qr_controller)

```verilog
wire [95:0]  nonce = {NONCE_PREFIX, msg_count};
wire [127:0] enc_plain = uart_enc ? cmd_payload[127:0] : sw_message;
```

- Nonce de 96 bits = 64 fijos + 32 del contador de mensajes.
- Multiplexor: si el cifrado viene del UART, se cifra lo que mandó la ESP32. Si viene de KEY1, se cifra el texto de los interruptores.
- Anchos de las salidas:
  - `packet` = 352 bits = 44 bytes: `{nonce 96, cifrado 128, etiqueta 128}`.
  - `text` = 480 bits = 60 caracteres Base64.
  - `matrix` = 1089 bits = 33 × 33 módulos del QR.
  - `mask` = máscara QR elegida (0–7).
- El controlador toma `key`, `nonce` y `plaintext` **en el flanco en que `start` = 1** y avisa con `done` cuando termina.

## Líneas 197–206: descifrado (crypto_decrypt_controller)

- `start(uart_dec)` arranca cuando llega un `'D'`.
- `text_in(cmd_payload)`: los 60 caracteres que leyó el celular.
- `.nonce_out()` y `.busy()` vacíos: son salidas que no usamos, y Quartus elimina esa lógica.
- `status_out`: 0 = OK, 1 = Base64 inválido, 2 = etiqueta incorrecta.

## Líneas 208–215: `status_char`

- Traduce el estado numérico al carácter del protocolo: 0 → `'K'`, 1 → `'B'`, otro → `'T'`.

## Líneas 217–282: la máquina de estados (el corazón del top)

**Registros (L217–220)**:
- `qr_valid`: hay un QR válido en pantalla.
- `shown_count`: número de mensaje que se muestra en los HEX.
- `shown_mask`: máscara del QR que se muestra.
- `dec_leds`: resultado del último descifrado.

**Reset (L223–233)**: todo a 0 y el estado en IDLE.

**L235–236, valores por defecto:**
```verilog
cmd_ack    <= 1'b0;
resp_start <= 1'b0;
```
- Así, cuando abajo se ponen en 1, **duran un solo ciclo (pulso)**. Es un patrón común: asignar el valor por defecto arriba y sobrescribirlo en el `case`.

**S_IDLE (L239–250)**:
- Si `enc_start`:
  - `msg_count <= msg_count + 1`. Como `<=` es **no bloqueante**, el controlador captura el valor **viejo** en este mismo flanco. El primer mensaje usa el contador 0, el segundo el 1, etc.
  - `qr_valid <= 0`: mientras cifra, la pantalla se pone gris y los HEX muestran `-`.
  - `cmd_ack <= uart_enc`: solo se confirma al UART si el comando vino de ahí. Con KEY1 no hay trama que confirmar.
  - Pasa a S_ENC.
- Si `uart_dec`: confirma la trama y pasa a S_DEC.

**S_ENC (L252–262)**, al llegar `enc_done`:
- Prende `qr_valid`.
- Guarda `packet[271:256]`: son los **16 bits bajos del nonce**, es decir, el contador. Se muestran en HEX3..HEX0.
  - Ubicación en el paquete: el nonce ocupa [351:256], y sus 16 bits inferiores son [271:256].
- Arma la respuesta `{"C", text}`: 8 + 480 = 488 bits = **61 bytes**.
- `resp_start <= 1` y pasa a S_RESP.

**S_DEC (L264–273)**, al llegar `dec_done`:
- `dec_leds` queda **one-hot** (un solo bit en 1): `001` correcto, `100` Base64 inválido, `010` etiqueta incorrecta.
- Respuesta `{"P", estado, 16 bytes, 344'd0}`.
  - 8 + 8 + 128 = 144 bits = **18 bytes** útiles.
  - Los 344 ceros solo rellenan hasta 488 bits (el ancho fijo del bus). Como `resp_len = 18`, el UART envía solo los primeros 18 bytes.

**S_RESP (L275–279)**:
```verilog
if (!resp_start && !resp_busy) state <= S_IDLE;
```
- Espera a que el UART termine de transmitir.
- ¿Por qué también `!resp_start`? En el primer ciclo de S_RESP, `resp_start` todavía es 1 y el puerto aún no sube `resp_busy`, porque lo sube un ciclo después. Sin esa condición, se regresaría a IDLE antes de empezar a enviar.

## Líneas 291–296: VGA

- `PIX_DIV(1)`: el reloj ya es de 25 MHz, que es el reloj de píxel de 640×480 a 60 Hz, así que no se divide más.
- Recibe la matriz y `valid`. Si `valid` = 0, dibuja el cuadro gris.

## Líneas 301–331: LEDs y displays

```verilog
wire busy_any = (state != S_IDLE);
assign LEDR = {5'd0, dec_leds[2], dec_leds[1], dec_leds[0], qr_valid, busy_any};
```

- Concatenación de 10 bits: LEDR9..5 apagados, LEDR4 Base64 inválido, LEDR3 etiqueta incorrecta, LEDR2 correcto, LEDR1 QR válido, LEDR0 ocupado.

**`seg7` (L304–324)**: decodificador hex → 7 segmentos, **activo en bajo**.
- Orden de bits: `{punto, g, f, e, d, c, b, a}`.
- Ejemplo `0` = `1100_0000`: punto y g apagados (1), a–f encendidos (0).
- Ejemplo `1` = `1111_1001`: solo b y c encendidos.

**L326–331**:
- Con QR: HEX3..HEX0 muestran el contador en hex y HEX5 la máscara.
- `8'hBF` = `1011_1111`: solo el segmento g (el del centro) encendido, es decir, un guion `-`.
- `8'hFF`: todo apagado (HEX4 no se usa).
- Son `assign`: lógica combinacional, sin reloj.

---

## Preguntas rápidas para practicar

1. ¿Qué pasa si presiono KEY1 mientras la FPGA está descifrando? → Se ignora: `key_enc` solo vale 1 en IDLE.
2. ¿Por qué el primer QR tiene contador 0 si se incrementa al arrancar? → Por la asignación no bloqueante: el controlador captura el valor viejo.
3. ¿Cuánto tarda en salir del reset al encender? → 2^20 ciclos / 25 MHz ≈ 42 ms, más 2 ciclos del sincronizador.
4. ¿Qué significa "activo en bajo"? → El botón o segmento está activo cuando vale 0.
5. ¿Por qué 2 flip-flops en cada entrada externa? → Para reducir la probabilidad de metaestabilidad (sincronizador).
6. ¿Cuántos bytes manda la respuesta `P`? → 18: `'P'`, estado y 16 de datos.
