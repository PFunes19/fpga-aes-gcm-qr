`timescale 1ns/1ps

// Controlador del prototipo: cifra un bloque y entrega el codigo QR.
//
//   texto original --AES-128-GCM--> {nonce, cifrado, etiqueta} (44 bytes)
//                  --Base64-------> 60 caracteres ASCII
//                  --qr_generator-> matriz QR 33x33 (version 4, nivel M)
//
// Instancia sin modificarlos: aes_gcm (con aes128_core, ghash, gf128_mult),
// base64_encode y qr_generator (con qr_data_encode, qr_rs_encoder, qr_matrix).
// Solo cifra: el descifrado y la verificacion corresponden al receptor.
//
// Entradas (capturadas en el flanco que acepta start; despues pueden cambiar):
//   key[127:0]       clave AES-128. El controlador no la guarda ni la protege.
//   nonce[95:0]      nonce de 12 bytes. NO debe repetirse con la misma clave.
//                    Este modulo no lo genera ni detecta repeticiones.
//   plaintext[127:0] exactamente 16 bytes; primer byte en [127:120].
//
// Salidas (se borran al aceptar start y se publican completas con done):
//   packet_out[351:0]  {nonce, cifrado, etiqueta}; primer byte en [351:344].
//   text_out[479:0]    los 60 caracteres Base64; primer caracter en [479:472].
//                      Es el mismo payload de 60 bytes que espera la UART.
//   matrix_out[1088:0] cuadro (fila,columna) en matrix_out[1088-(fila*33+columna)],
//                      1=negro, 0=blanco, sin margen. Agregar 4 modulos blancos.
//   mask_out[2:0]      mascara QR elegida.
//   busy               activo durante toda la solicitud, tambien entre etapas.
//   done               pulso de un ciclo cuando todo queda disponible.
//
// Control: start es un pulso con busy=0. Se ignora durante busy, incluido el
// ciclo de finalizacion; no hay cola. Reset asincrono, activo en alto,
// compartido por todos los submodulos: cancela la solicitud en cualquier etapa.
//
// Ciclos desde la aceptacion de start (con las implementaciones actuales):
//       0  acepta y arranca aes_gcm
//     300  cifrado y etiqueta listos
//     301  arranca base64_encode
//     316  texto Base64 listo
//     317  arranca qr_generator
//   29797  matriz lista
//   29798  publica salidas y done; baja busy
// Latencia total 29798 ciclos: 595.96 us a 50 MHz, si Quartus cierra tiempos.
// El controlador espera los done de cada etapa; no usa contadores fijos.

module crypto_qr_controller (
    input  wire          clk,
    input  wire          reset,
    input  wire          start,
    input  wire [127:0]  key,
    input  wire [95:0]   nonce,
    input  wire [127:0]  plaintext,

    output reg  [351:0]  packet_out,
    output reg  [479:0]  text_out,
    output reg  [1088:0] matrix_out,
    output reg  [2:0]    mask_out,
    output reg           busy,
    output reg           done
);

    localparam [1:0] IDLE        = 2'd0,
                     WAIT_GCM    = 2'd1,
                     WAIT_BASE64 = 2'd2,
                     WAIT_QR     = 2'd3;
    reg [1:0] state;

    // aes_gcm no publica el nonce, pero el paquete lo necesita.
    reg [95:0] nonce_reg;

    wire [127:0]  ciphertext;
    wire [127:0]  tag;
    wire          gcm_done;
    wire [479:0]  encoded_text;
    wire          base64_done;
    wire [1088:0] qr_bits;
    wire [2:0]    qr_mask;
    wire          qr_done;

    // Un done registrado garantiza que la salida de esa etapa ya es valida,
    // asi que la siguiente etapa la captura en ese mismo flanco.
    wire gcm_start    = (state == IDLE) && start;
    wire base64_start = (state == WAIT_GCM) && gcm_done;
    wire qr_start     = (state == WAIT_BASE64) && base64_done;

    wire [351:0] packet = {nonce_reg, ciphertext, tag};

    aes_gcm cifrador (
        .clk(clk),
        .reset(reset),
        .start(gcm_start),
        .decrypt(1'b0),
        .key(key),
        .nonce(nonce),
        .data_in(plaintext),
        .tag_in(128'd0),
        .data_out(ciphertext),
        .tag_out(tag),
        .busy(),
        .done(gcm_done),
        .error()
    );

    base64_encode codificador (
        .clk(clk),
        .reset(reset),
        .start(base64_start),
        .data_in(packet),
        .text_out(encoded_text),
        .busy(),
        .done(base64_done)
    );

    qr_generator generador_qr (
        .clk(clk),
        .reset(reset),
        .start(qr_start),
        .text_in(encoded_text),
        .matrix_out(qr_bits),
        .mask_out(qr_mask),
        .busy(),
        .done(qr_done)
    );

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state      <= IDLE;
            nonce_reg  <= 96'd0;
            packet_out <= 352'd0;
            text_out   <= 480'd0;
            matrix_out <= 1089'd0;
            mask_out   <= 3'd0;
            busy       <= 1'b0;
            done       <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        nonce_reg  <= nonce;
                        packet_out <= 352'd0;
                        text_out   <= 480'd0;
                        matrix_out <= 1089'd0;
                        mask_out   <= 3'd0;
                        busy       <= 1'b1;
                        state      <= WAIT_GCM;
                    end
                end

                WAIT_GCM: begin
                    if (gcm_done)
                        state <= WAIT_BASE64;
                end

                WAIT_BASE64: begin
                    if (base64_done)
                        state <= WAIT_QR;
                end

                WAIT_QR: begin
                    if (qr_done) begin
                        // Las salidas de cada etapa se conservan hasta su
                        // siguiente start, que solo llega con otra solicitud.
                        packet_out <= packet;
                        text_out   <= encoded_text;
                        matrix_out <= qr_bits;
                        mask_out   <= qr_mask;
                        busy       <= 1'b0;
                        done       <= 1'b1;
                        state      <= IDLE;
                    end
                end
            endcase
        end
    end

endmodule
