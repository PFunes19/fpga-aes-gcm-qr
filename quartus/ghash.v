`timescale 1ns/1ps

// GHASH por bloques de 128 bits, usando gf128_mult.v.
// NIST SP 800-38D, seccion 6.4: Y_0 = 0; Y_i = (Y_(i-1) XOR X_i) * H.
// https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf
//
// Uso:
// - start: pulso de un ciclo cuando busy == 0, uno por bloque.
// - first = 1 con start: primer bloque de una nueva secuencia; captura h_in
//   y calcula block_in * H, sin acumular el resultado de la secuencia previa.
// - first = 0 con start: continua la secuencia con la H ya capturada.
//   En este caso h_in se ignora. El primer bloque debe usar first = 1.
// - Captura block_in al aceptar start; ignora solicitudes durante busy.
// - done: pulso por bloque, 130 ciclos despues de aceptar start.
// - hash_out: acumulado actualizado al terminar cada bloque. Conserva su
//   valor entre operaciones; despues del ultimo bloque es el GHASH completo.
// - reset: asincrono, activo en alto; cancela tambien al multiplicador.
//
// El emisor suministra los bloques ya preparados, incluidos los ceros de
// relleno y el bloque de longitudes que GCM requiere. Este modulo no genera
// H, no detecta el ultimo bloque y no calcula por si solo la etiqueta GCM.

module ghash (
    input  wire         clk,
    input  wire         reset,
    input  wire         start,
    input  wire         first,
    input  wire [127:0] h_in,
    input  wire [127:0] block_in,

    output reg  [127:0] hash_out,
    output reg          busy,
    output reg          done
);

    reg [127:0] h_reg;
    reg [127:0] mult_input;
    reg         mult_start;

    wire [127:0] mult_product;
    wire         mult_done;

    // Este modulo es el unico que inicia el multiplicador. No acepta otro
    // bloque hasta recoger su resultado, por lo que no necesita mult_busy.
    gf128_mult multiplicador (
        .clk(clk),
        .reset(reset),
        .start(mult_start),
        .x_in(mult_input),
        .y_in(h_reg),
        .product_out(mult_product),
        .busy(),
        .done(mult_done)
    );

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            h_reg      <= 128'd0;
            mult_input <= 128'd0;
            mult_start <= 1'b0;
            hash_out   <= 128'd0;
            busy       <= 1'b0;
            done       <= 1'b0;
        end else begin
            mult_start <= 1'b0;
            done       <= 1'b0;

            if (busy) begin
                if (mult_done) begin
                    hash_out <= mult_product;
                    busy     <= 1'b0;
                    done     <= 1'b1;
                end
            end else if (start) begin
                if (first) begin
                    h_reg      <= h_in;
                    mult_input <= block_in;
                end else begin
                    mult_input <= hash_out ^ block_in;
                end

                // El multiplicador captura estos datos en el proximo flanco.
                mult_start <= 1'b1;
                busy       <= 1'b1;
            end
        end
    end

endmodule
