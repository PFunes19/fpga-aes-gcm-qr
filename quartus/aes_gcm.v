`timescale 1ns/1ps

// AES-128-GCM para el tamano PROVISIONAL del prototipo:
// - Exactamente 16 bytes de datos (un bloque).
// - Nonce/IV de 12 bytes (96 bits).
// - Etiqueta de 16 bytes (128 bits).
// - Sin datos adicionales autenticados: AAD vacio.
// No admite otras longitudes ni mensajes vacios.
// Esta limitacion no define aun el formato final de los cinco campos.
//
// Dependencias: aes128_core.v, ghash.v y gf128_mult.v.
// Referencia: NIST SP 800-38D, secciones 7.1 y 7.2.
// https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf
//
// Uso:
// - start: pulso con busy == 0; captura todas las entradas.
// - decrypt = 0: data_in es el texto original, tag_in se ignora.
// - decrypt = 1: data_in es el cifrado y tag_in la etiqueta recibida.
// - Ignora nuevas solicitudes mientras esta ocupado.
// - done: pulso al terminar, 300 ciclos despues de aceptar start.
// - done == 1 y error == 0: resultado valido en data_out y tag_out.
//   Al cifrar, data_out es el cifrado y tag_out la etiqueta calculada.
//   Al descifrar, data_out es el original y tag_out la etiqueta verificada.
// - done == 1 y error == 1: autenticacion fallida; ambas salidas son cero.
// - error es un pulso de un ciclo, coincidente con done.
// - Las salidas se borran al aceptar start y permanecen en cero hasta validar
//   el resultado. El texto descifrado provisional nunca sale por data_out.
// - reset: asincrono, activo en alto, cancela todos los bloques internos.
//
// El controlador externo debe suministrar una clave y un nonce. NO debe
// repetir un nonce con la misma clave al CIFRAR mensajes. Este modulo no
// genera nonces, no detecta repeticiones y no resuelve su persistencia ni
// el almacenamiento protegido de la clave. Esas tareas siguen pendientes.
// El primer byte de cada entrada ocupa sus bits mas significativos.

module aes_gcm (
    input  wire         clk,
    input  wire         reset,
    input  wire         start,
    input  wire         decrypt,
    input  wire [127:0] key,
    input  wire [95:0]  nonce,
    input  wire [127:0] data_in,
    input  wire [127:0] tag_in,

    output reg  [127:0] data_out,
    output reg  [127:0] tag_out,
    output reg          busy,
    output reg          done,
    output reg          error
);

    localparam [2:0] IDLE             = 3'd0,
                     WAIT_H           = 3'd1,
                     WAIT_MASK        = 3'd2,
                     WAIT_STREAM      = 3'd3,
                     WAIT_C_HASH      = 3'd4,
                     WAIT_LENGTH_HASH = 3'd5;

    // GCM expresa las longitudes en BITS: AAD = 0, cifrado = 128.
    localparam [127:0] LENGTH_BLOCK = {64'd0, 64'd128};

    reg [2:0]   state;
    reg         decrypt_reg;
    reg [127:0] key_reg;
    reg [95:0]  nonce_reg;
    reg [127:0] data_reg;
    reg [127:0] tag_reg;
    reg [127:0] h_reg;
    reg [127:0] tag_mask;
    reg [127:0] pending_result;

    reg         aes_start;
    reg [127:0] aes_input;
    wire [127:0] aes_output;
    wire         aes_done;

    reg         hash_start;
    reg         hash_first;
    reg [127:0] hash_input;
    wire [127:0] hash_output;
    wire         hash_done;

    wire [127:0] transformed_data;
    wire [127:0] calculated_tag;
    assign transformed_data = data_reg ^ aes_output;
    assign calculated_tag = tag_mask ^ hash_output;

    // Se reutiliza un solo nucleo AES para H, la mascara y el contador.
    // El control solo vuelve a iniciarlo despues de recibir su done.
    aes128_core nucleo_aes (
        .clk(clk),
        .reset(reset),
        .start(aes_start),
        .key(key_reg),
        .block_in(aes_input),
        .block_out(aes_output),
        .busy(),
        .done(aes_done)
    );

    ghash autenticador (
        .clk(clk),
        .reset(reset),
        .start(hash_start),
        .first(hash_first),
        .h_in(h_reg),
        .block_in(hash_input),
        .hash_out(hash_output),
        .busy(),
        .done(hash_done)
    );

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state          <= IDLE;
            decrypt_reg    <= 1'b0;
            key_reg        <= 128'd0;
            nonce_reg      <= 96'd0;
            data_reg       <= 128'd0;
            tag_reg        <= 128'd0;
            h_reg          <= 128'd0;
            tag_mask       <= 128'd0;
            pending_result <= 128'd0;
            aes_start      <= 1'b0;
            aes_input      <= 128'd0;
            hash_start     <= 1'b0;
            hash_first     <= 1'b0;
            hash_input     <= 128'd0;
            data_out       <= 128'd0;
            tag_out        <= 128'd0;
            busy           <= 1'b0;
            done           <= 1'b0;
            error          <= 1'b0;
        end else begin
            aes_start  <= 1'b0;
            hash_start <= 1'b0;
            done       <= 1'b0;
            error      <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        decrypt_reg    <= decrypt;
                        key_reg        <= key;
                        nonce_reg      <= nonce;
                        data_reg       <= data_in;
                        tag_reg        <= tag_in;
                        pending_result <= 128'd0;
                        data_out       <= 128'd0;
                        tag_out        <= 128'd0;
                        busy           <= 1'b1;

                        // H = AES_K(0^128).
                        aes_input <= 128'd0;
                        aes_start <= 1'b1;
                        state     <= WAIT_H;
                    end
                end

                WAIT_H: begin
                    if (aes_done) begin
                        h_reg <= aes_output;

                        // Con nonce de 96 bits: J0 = nonce || 00000001.
                        // Calcula AES_K(J0), la mascara de la etiqueta.
                        aes_input <= {nonce_reg, 32'h00000001};
                        aes_start <= 1'b1;
                        state     <= WAIT_MASK;
                    end
                end

                WAIT_MASK: begin
                    if (aes_done) begin
                        tag_mask <= aes_output;

                        // Un solo bloque de datos: contador = inc32(J0).
                        aes_input <= {nonce_reg, 32'h00000002};
                        aes_start <= 1'b1;
                        state     <= WAIT_STREAM;
                    end
                end

                WAIT_STREAM: begin
                    if (aes_done) begin
                        // GCM usa el mismo XOR para cifrar y descifrar.
                        // El resultado queda interno hasta verificar el tag.
                        pending_result <= transformed_data;

                        // GHASH siempre procesa el CIFRADO: al descifrar
                        // ya venia en data_in; al cifrar acabamos de crearlo.
                        if (decrypt_reg)
                            hash_input <= data_reg;
                        else
                            hash_input <= transformed_data;

                        hash_first <= 1'b1;
                        hash_start <= 1'b1;
                        state      <= WAIT_C_HASH;
                    end
                end

                WAIT_C_HASH: begin
                    if (hash_done) begin
                        // Segundo bloque GHASH: longitudes AAD y cifrado.
                        hash_input <= LENGTH_BLOCK;
                        hash_first <= 1'b0;
                        hash_start <= 1'b1;
                        state      <= WAIT_LENGTH_HASH;
                    end
                end

                WAIT_LENGTH_HASH: begin
                    if (hash_done) begin
                        // T = AES_K(J0) XOR GHASH(C || bloque_longitudes).
                        if (!decrypt_reg || (calculated_tag == tag_reg)) begin
                            data_out <= pending_result;
                            tag_out  <= calculated_tag;
                        end else begin
                            // No entrega ni el texto provisional ni un tag
                            // calculado para un mensaje que no autentica.
                            data_out <= 128'd0;
                            tag_out  <= 128'd0;
                            error    <= 1'b1;
                        end

                        pending_result <= 128'd0;
                        busy           <= 1'b0;
                        done           <= 1'b1;
                        state          <= IDLE;
                    end
                end

                default: begin
                    state    <= IDLE;
                    busy     <= 1'b0;
                    data_out <= 128'd0;
                    tag_out  <= 128'd0;
                end
            endcase
        end
    end

endmodule
