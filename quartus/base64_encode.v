`timescale 1ns/1ps

// Base64 estandar RFC 4648, longitud FIJA: 44 bytes -> 60 caracteres ASCII.
// Alfabeto A-Z, a-z, 0-9, +, / y un unico '=' al final. Sin salto de linea
// ni terminador NUL. No es Base64url. https://www.rfc-editor.org/rfc/rfc4648
//
// Paquete de esta version: {nonce[95:0], cifrado[127:0], etiqueta[127:0]}.
// data_in[351:256] = nonce, [255:128] = cifrado, [127:0] = etiqueta.
// El primer byte binario esta en [351:344]; el primer caracter ASCII de
// text_out esta en [479:472]. Es el orden del payload UART de 60 bytes.
//
// start: pulso cuando busy=0; captura los 44 bytes completos.
// Procesa tres bytes por ciclo (dos en el ultimo grupo).
// done: pulso 15 ciclos despues de aceptar start.
// text_out se borra al aceptar start y solo se publica completo al terminar.
// Ignora start durante busy. Reset asincrono activo en alto.

module base64_encode (
    input  wire         clk,
    input  wire         reset,
    input  wire         start,
    input  wire [351:0] data_in,

    output reg  [479:0] text_out,
    output reg          busy,
    output reg          done
);

    // Ocho ceros al final completan el ultimo grupo de 24 bits.
    reg [359:0] data_shift;
    reg [479:0] text_buffer;
    reg [3:0]   group_count;

    wire [31:0] encoded_group;
    wire [479:0] next_text;

    function [7:0] encode_char;
        input [5:0] value;
        begin
            if (value < 6'd26)
                encode_char = 8'h41 + {2'b00, value};
            else if (value < 6'd52)
                encode_char = 8'h61 + ({2'b00, value} - 8'd26);
            else if (value < 6'd62)
                encode_char = 8'h30 + ({2'b00, value} - 8'd52);
            else if (value == 6'd62)
                encode_char = 8'h2B; // +
            else
                encode_char = 8'h2F; // /
        end
    endfunction

    assign encoded_group = {
        encode_char(data_shift[359:354]),
        encode_char(data_shift[353:348]),
        encode_char(data_shift[347:342]),
        (group_count == 4'd14) ? 8'h3D : encode_char(data_shift[341:336])
    };
    assign next_text = {text_buffer[447:0], encoded_group};

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            data_shift <= 360'd0;
            text_buffer <= 480'd0;
            group_count <= 4'd0;
            text_out <= 480'd0;
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;

            if (busy) begin
                text_buffer <= next_text;
                data_shift <= {data_shift[335:0], 24'd0};

                if (group_count == 4'd14) begin
                    text_out <= next_text;
                    group_count <= 4'd0;
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    group_count <= group_count + 1'b1;
                end
            end else if (start) begin
                data_shift <= {data_in, 8'd0};
                text_buffer <= 480'd0;
                group_count <= 4'd0;
                text_out <= 480'd0;
                busy <= 1'b1;
            end
        end
    end

endmodule
