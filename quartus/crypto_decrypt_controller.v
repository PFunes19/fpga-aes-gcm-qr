`timescale 1ns/1ps

// Controlador de descifrado: el camino inverso de crypto_qr_controller.
//
//   60 caracteres Base64 --base64_decode--> {nonce, cifrado, etiqueta}
//                        --aes_gcm (decrypt=1)--> texto original de 16 bytes
//
// Instancia sin modificarlos: base64_decode y aes_gcm (con aes128_core,
// ghash, gf128_mult).
//
// Entradas (capturadas en el flanco que acepta start):
//   key[127:0]      clave AES-128 (la misma con la que se cifro).
//   text_in[479:0]  60 caracteres Base64; primer caracter en [479:472].
//
// Salidas (se borran al aceptar start y se publican con done):
//   plaintext_out[127:0]  texto original; solo distinto de cero si status=OK.
//   nonce_out[95:0]       nonce leido del paquete (si el Base64 es valido).
//   status_out[1:0]       0 = OK, etiqueta GCM correcta
//                         1 = Base64 invalido (no se intento descifrar)
//                         2 = etiqueta GCM incorrecta (paquete alterado o
//                             clave distinta); plaintext_out = 0
//   busy, done            mismo convenio que el resto de modulos.
//
// start durante busy se ignora. Reset asincrono, activo en alto.
// Latencia: 15 ciclos (Base64) + 1 + 300 (GCM) + 1 si el texto es valido;
// menor si Base64 falla, porque base64_decode termina en el primer error.

module crypto_decrypt_controller (
    input  wire          clk,
    input  wire          reset,
    input  wire          start,
    input  wire [127:0]  key,
    input  wire [479:0]  text_in,

    output reg  [127:0]  plaintext_out,
    output reg  [95:0]   nonce_out,
    output reg  [1:0]    status_out,
    output reg           busy,
    output reg           done
);

    localparam [1:0] ST_OK = 2'd0, ST_BASE64 = 2'd1, ST_TAG = 2'd2;

    localparam [1:0] IDLE        = 2'd0,
                     WAIT_BASE64 = 2'd1,
                     WAIT_GCM    = 2'd2;
    reg [1:0]   state;
    reg [127:0] key_reg;

    wire [351:0] packet;
    wire         b64_done, b64_error;
    wire [127:0] gcm_data;
    wire         gcm_done, gcm_error;

    wire b64_start = (state == IDLE) && start;
    // done registrado: el paquete ya es valido en este flanco.
    wire gcm_start = (state == WAIT_BASE64) && b64_done && !b64_error;

    base64_decode decodificador (
        .clk(clk),
        .reset(reset),
        .start(b64_start),
        .text_in(text_in),
        .data_out(packet),
        .busy(),
        .done(b64_done),
        .error(b64_error)
    );

    aes_gcm descifrador (
        .clk(clk),
        .reset(reset),
        .start(gcm_start),
        .decrypt(1'b1),
        .key(key_reg),
        .nonce(packet[351:256]),
        .data_in(packet[255:128]),
        .tag_in(packet[127:0]),
        .data_out(gcm_data),
        .tag_out(),
        .busy(),
        .done(gcm_done),
        .error(gcm_error)
    );

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state         <= IDLE;
            key_reg       <= 128'd0;
            plaintext_out <= 128'd0;
            nonce_out     <= 96'd0;
            status_out    <= ST_OK;
            busy          <= 1'b0;
            done          <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: begin
                    if (start) begin
                        key_reg       <= key;
                        plaintext_out <= 128'd0;
                        nonce_out     <= 96'd0;
                        status_out    <= ST_OK;
                        busy          <= 1'b1;
                        state         <= WAIT_BASE64;
                    end
                end

                WAIT_BASE64: begin
                    if (b64_done) begin
                        if (b64_error) begin
                            status_out <= ST_BASE64;
                            busy       <= 1'b0;
                            done       <= 1'b1;
                            state      <= IDLE;
                        end else begin
                            nonce_out <= packet[351:256];
                            state     <= WAIT_GCM;
                        end
                    end
                end

                WAIT_GCM: begin
                    if (gcm_done) begin
                        plaintext_out <= gcm_error ? 128'd0 : gcm_data;
                        status_out    <= gcm_error ? ST_TAG : ST_OK;
                        busy          <= 1'b0;
                        done          <= 1'b1;
                        state         <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
