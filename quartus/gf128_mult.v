`timescale 1ns/1ps

// Multiplicador GF(2^128) para GCM, un bit por ciclo.
// Referencia: NIST SP 800-38D, seccion 6.3, algoritmo 1.
// https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf
//
// Uso:
// - start: pulso de un ciclo cuando busy == 0.
// - Captura x_in e y_in al aceptar start.
// - Ignora start mientras busy == 1, incluido el ciclo final.
// - done: pulso de un ciclo, 128 ciclos despues de aceptar start.
// - product_out conserva el ultimo resultado hasta terminar otro producto.
// - reset: asincrono, activo en alto; cancela la operacion.
//
// Orden de bits de GCM: se procesa primero x_in[127].
// El elemento identidad es 128'h80000000000000000000000000000000.
// Esta operacion no es una multiplicacion de enteros con el operador *.

module gf128_mult (
    input  wire         clk,
    input  wire         reset,
    input  wire         start,
    input  wire [127:0] x_in,
    input  wire [127:0] y_in,

    output reg  [127:0] product_out,
    output reg          busy,
    output reg          done
);

    // Constante de reduccion para la representacion de bits de GCM.
    localparam [127:0] R = 128'hE1000000000000000000000000000000;

    reg [127:0] x_reg;
    reg [127:0] v;
    reg [127:0] z;
    reg [6:0]   bit_count;

    wire [127:0] z_next;
    assign z_next = x_reg[127] ? (z ^ v) : z;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            x_reg       <= 128'd0;
            v           <= 128'd0;
            z           <= 128'd0;
            bit_count   <= 7'd0;
            product_out <= 128'd0;
            busy        <= 1'b0;
            done        <= 1'b0;
        end else begin
            done <= 1'b0;

            if (busy) begin
                // Acumula la contribucion del bit actual de X.
                z <= z_next;

                // Deja el siguiente bit de X en la posicion [127].
                x_reg <= {x_reg[126:0], 1'b0};

                // Desplaza V y aplica la reduccion si su bit inferior es 1.
                if (v[0])
                    v <= {1'b0, v[127:1]} ^ R;
                else
                    v <= {1'b0, v[127:1]};

                if (bit_count == 7'd127) begin
                    // Usa z_next para incluir tambien el ultimo bit.
                    product_out <= z_next;
                    bit_count   <= 7'd0;
                    busy        <= 1'b0;
                    done        <= 1'b1;
                end else begin
                    bit_count <= bit_count + 1'b1;
                end
            end else if (start) begin
                x_reg     <= x_in;
                v         <= y_in;
                z         <= 128'd0;
                bit_count <= 7'd0;
                busy      <= 1'b1;
            end
        end
    end

endmodule
