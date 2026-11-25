`timescale 1ns/1ps

// Base64 estandar estricto RFC 4648, FIJO: 60 caracteres -> 44 bytes.
// Solo A-Z, a-z, 0-9, + y / en los primeros 59 caracteres; el ultimo debe
// ser '='. Los dos bits de relleno del caracter 59 deben ser cero.
// Rechaza espacios, CR/LF, NUL, Base64url y relleno no canonico.
// https://www.rfc-editor.org/rfc/rfc4648 (secciones 3.3, 3.5 y 4).
//
// Primer caracter en text_in[479:472]. Paquete de salida:
// data_out[351:256] = nonce, [255:128] = cifrado, [127:0] = etiqueta.
// El transporte debe entregar exactamente 60 caracteres; no hay puerto
// de longitud porque este modulo solo admite el tamano fijo del prototipo.
//
// start: pulso cuando busy=0; captura todo el texto.
// Texto valido: done pulsa tras 15 ciclos y error=0.
// Texto invalido: termina al detectar el primer grupo incorrecto, con
// done=1, error=1 y data_out=0. No publica resultados parciales.
// done/error duran un ciclo. data_out se borra al aceptar start.
// Ignora start durante busy. Reset asincrono activo en alto.
// Que Base64 sea valido NO significa que la etiqueta GCM sea valida.

module base64_decode (
    input  wire         clk,
    input  wire         reset,
    input  wire         start,
    input  wire [479:0] text_in,

    output reg  [351:0] data_out,
    output reg          busy,
    output reg          done,
    output reg          error
);

    reg [479:0] text_shift;
    reg [351:0] data_buffer;
    reg [3:0]   group_count;

    wire [6:0] d0, d1, d2, d3;
    wire [23:0] decoded_group;
    wire group_valid;

    // Bit 6: caracter valido. Bits 5:0: valor de su grupo de seis bits.
    function [6:0] decode_char;
        input [7:0] character;
        reg [7:0] value;
        begin
            value = 8'd0;
            decode_char = 7'd0;
            if ((character >= 8'h41) && (character <= 8'h5A)) begin
                value = character - 8'h41;
                decode_char = {1'b1, value[5:0]};
            end else if ((character >= 8'h61) && (character <= 8'h7A)) begin
                value = character - 8'h61 + 8'd26;
                decode_char = {1'b1, value[5:0]};
            end else if ((character >= 8'h30) && (character <= 8'h39)) begin
                value = character - 8'h30 + 8'd52;
                decode_char = {1'b1, value[5:0]};
            end else if (character == 8'h2B) begin
                decode_char = {1'b1, 6'd62};
            end else if (character == 8'h2F) begin
                decode_char = {1'b1, 6'd63};
            end
        end
    endfunction

    assign d0 = decode_char(text_shift[479:472]);
    assign d1 = decode_char(text_shift[471:464]);
    assign d2 = decode_char(text_shift[463:456]);
    assign d3 = decode_char(text_shift[455:448]);
    assign decoded_group = {d0[5:0], d1[5:0], d2[5:0], d3[5:0]};

    assign group_valid = d0[6] && d1[6] && d2[6] &&
        ((group_count == 4'd14) ?
            ((text_shift[455:448] == 8'h3D) && (d2[1:0] == 2'b00)) :
            d3[6]);

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            text_shift <= 480'd0;
            data_buffer <= 352'd0;
            group_count <= 4'd0;
            data_out <= 352'd0;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
        end else begin
            done <= 1'b0;
            error <= 1'b0;

            if (busy) begin
                if (group_valid) begin
                    text_shift <= {text_shift[447:0], 32'd0};

                    if (group_count == 4'd14) begin
                        // Los 14 grupos previos aportaron 42 bytes. El
                        // ultimo aporta dos; se excluyen los bits de relleno.
                        data_out <= {data_buffer[335:0], decoded_group[23:8]};
                        group_count <= 4'd0;
                        busy <= 1'b0;
                        done <= 1'b1;
                    end else begin
                        data_buffer <= {data_buffer[327:0], decoded_group};
                        group_count <= group_count + 1'b1;
                    end
                end else begin
                    data_buffer <= 352'd0;
                    data_out <= 352'd0;
                    group_count <= 4'd0;
                    busy <= 1'b0;
                    done <= 1'b1;
                    error <= 1'b1;
                end
            end else if (start) begin
                text_shift <= text_in;
                data_buffer <= 352'd0;
                group_count <= 4'd0;
                data_out <= 352'd0;
                busy <= 1'b1;
            end
        end
    end

endmodule
