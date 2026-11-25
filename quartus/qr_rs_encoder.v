`timescale 1ns/1ps

// Reed-Solomon e intercalado para QR Model 2, version 4, correccion M.
// Entrada: 64 bytes de datos de qr_data_encode, primer byte en [511:504].
// Se divide en dos bloques de 32 bytes, con 18 bytes de paridad cada uno.
// Salida: 100 codewords, primer byte en codewords_out[799:792].
//
// Orden final:
// D0[0], D1[0], ... D0[31], D1[31], E0[0], E1[0], ... E0[17], E1[17].
// D0 corresponde a los primeros 32 bytes de entrada; D1 a los siguientes.
// E0 y E1 son sus bytes de correccion. No incluye los bits restantes de la
// matriz QR, patrones, informacion de formato ni mascara.
//
// Campo GF(256), polinomio 0x11D, alpha=2.
// Generador g(x) = producto de (x + alpha^i), i=0..17, grado 18.
// Este campo es distinto del GF(2^128) de GCM y del GF(256) de AES.
//
// start: pulso cuando busy=0; captura los 64 bytes completos.
// Se reutiliza UN multiplicador GF(256), un coeficiente por ciclo.
// Cada byte requiere 1 ciclo de carga + 18 de actualizacion de paridad.
// done: pulso 1219 ciclos despues de aceptar start:
//   2 * (32 * 19 + 1 almacenamiento) + 1 publicacion.
// Ignora start durante busy. codewords_out se borra al iniciar y solo
// se publica completo con done; se conserva hasta la siguiente solicitud.
// Reset asincrono activo en alto. No tiene dependencias de otros modulos.

module qr_rs_encoder (
    input  wire         clk,
    input  wire         reset,
    input  wire         start,
    input  wire [511:0] data_in,

    output reg  [799:0] codewords_out,
    output reg          busy,
    output reg          done
);

    localparam [2:0] IDLE       = 3'd0,
                     LOAD_BYTE  = 3'd1,
                     UPDATE_ECC = 3'd2,
                     STORE_ECC  = 3'd3,
                     FINISH     = 3'd4;

    reg [2:0] state;
    reg [511:0] data_shift;
    reg [799:0] codeword_buffer;
    reg [7:0] ecc [0:17];
    reg [7:0] factor;
    reg [4:0] byte_count;
    reg [4:0] coefficient_index;
    reg block_id;
    integer i;

    wire [7:0] product;

    // Multiplicacion en GF(256) para QR. Los ocho pasos son combinacionales.
    function [7:0] gf_multiply;
        input [7:0] a;
        input [7:0] b;
        reg [7:0] x, y, result;
        integer bit_index;
        begin
            x = a;
            y = b;
            result = 8'd0;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (y[0])
                    result = result ^ x;
                x = {x[6:0], 1'b0} ^ (x[7] ? 8'h1D : 8'h00);
                y = {1'b0, y[7:1]};
            end
            gf_multiply = result;
        end
    endfunction

    // Coeficientes de g(x), desde x^17 hasta x^0.
    // El coeficiente principal de x^18 es 1 y se omite en esta tabla.
    function [7:0] generator_coefficient;
        input [4:0] index;
        begin
            case (index)
                5'd0:  generator_coefficient = 8'hEF;
                5'd1:  generator_coefficient = 8'hFB;
                5'd2:  generator_coefficient = 8'hB7;
                5'd3:  generator_coefficient = 8'h71;
                5'd4:  generator_coefficient = 8'h95;
                5'd5:  generator_coefficient = 8'hAF;
                5'd6:  generator_coefficient = 8'hC7;
                5'd7:  generator_coefficient = 8'hD7;
                5'd8:  generator_coefficient = 8'hF0;
                5'd9:  generator_coefficient = 8'hDC;
                5'd10: generator_coefficient = 8'h49;
                5'd11: generator_coefficient = 8'h52;
                5'd12: generator_coefficient = 8'hAD;
                5'd13: generator_coefficient = 8'h4B;
                5'd14: generator_coefficient = 8'h20;
                5'd15: generator_coefficient = 8'h43;
                5'd16: generator_coefficient = 8'hD9;
                5'd17: generator_coefficient = 8'h92;
                default: generator_coefficient = 8'd0;
            endcase
        end
    endfunction

    // Alterna los bytes de ambos bloques de datos sin modificar su valor.
    function [511:0] interleave_data;
        input [511:0] value;
        integer n;
        begin
            for (n = 0; n < 32; n = n + 1) begin
                interleave_data[511 - 16*n -: 8] = value[511 - 8*n -: 8];
                interleave_data[503 - 16*n -: 8] = value[255 - 8*n -: 8];
            end
        end
    endfunction

    assign product = gf_multiply(factor, generator_coefficient(coefficient_index));

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            data_shift <= 512'd0;
            codeword_buffer <= 800'd0;
            for (i = 0; i < 18; i = i + 1)
                ecc[i] <= 8'd0;
            factor <= 8'd0;
            byte_count <= 5'd0;
            coefficient_index <= 5'd0;
            block_id <= 1'b0;
            codewords_out <= 800'd0;
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        data_shift <= data_in;
                        codeword_buffer <= {interleave_data(data_in), 288'd0};
                        for (i = 0; i < 18; i = i + 1)
                            ecc[i] <= 8'd0;
                        factor <= 8'd0;
                        byte_count <= 5'd0;
                        coefficient_index <= 5'd0;
                        block_id <= 1'b0;
                        codewords_out <= 800'd0;
                        busy <= 1'b1;
                        state <= LOAD_BYTE;
                    end
                end

                LOAD_BYTE: begin
                    factor <= data_shift[511:504] ^ ecc[0];
                    data_shift <= {data_shift[503:0], 8'd0};
                    coefficient_index <= 5'd0;
                    state <= UPDATE_ECC;
                end

                UPDATE_ECC: begin
                    // Actualizar en orden ascendente conserva ecc[i+1]
                    // hasta que se haya utilizado para calcular ecc[i].
                    if (coefficient_index == 5'd17)
                        ecc[17] <= product;
                    else
                        ecc[coefficient_index] <= ecc[coefficient_index + 1'b1] ^ product;

                    if (coefficient_index == 5'd17) begin
                        coefficient_index <= 5'd0;
                        if (byte_count == 5'd31) begin
                            state <= STORE_ECC;
                        end else begin
                            byte_count <= byte_count + 1'b1;
                            state <= LOAD_BYTE;
                        end
                    end else begin
                        coefficient_index <= coefficient_index + 1'b1;
                    end
                end

                STORE_ECC: begin
                    // La ultima actualizacion ya esta registrada. Coloca
                    // la paridad en los 36 bytes finales, tambien alternada.
                    for (i = 0; i < 18; i = i + 1) begin
                        if (!block_id)
                            codeword_buffer[287 - 16*i -: 8] <= ecc[i];
                        else
                            codeword_buffer[279 - 16*i -: 8] <= ecc[i];
                    end

                    if (!block_id) begin
                        // Cada bloque tiene su propia division polinomial.
                        for (i = 0; i < 18; i = i + 1)
                            ecc[i] <= 8'd0;
                        block_id <= 1'b1;
                        byte_count <= 5'd0;
                        state <= LOAD_BYTE;
                    end else begin
                        state <= FINISH;
                    end
                end

                FINISH: begin
                    codewords_out <= codeword_buffer;
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= IDLE;
                end

                default: begin
                    state <= IDLE;
                    busy <= 1'b0;
                    codewords_out <= 800'd0;
                end
            endcase
        end
    end

endmodule
