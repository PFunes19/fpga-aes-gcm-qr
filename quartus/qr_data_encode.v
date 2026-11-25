`timescale 1ns/1ps

// Primera etapa del generador QR: prepara los codewords de DATOS.
// Perfil de esta version: QR Model 2, version 4, correccion M, modo byte,
// un segmento de exactamente 60 bytes. No agrega ECI ni optimiza segmentos.
// Los 60 caracteres Base64 de nuestro prototipo son ASCII.
//
// Entrada: 60 bytes, primer caracter en text_in[479:472].
// Salida: 64 codewords de datos, primer byte en data_out[511:504].
// Estos 64 bytes incluyen la cabecera y el relleno; el contenido sigue
// siendo de 60 bytes. No son los pixeles/modulos de la matriz QR.
//
// Formato de los 512 bits, del mas significativo al menos significativo:
//   modo byte       4 bits: 0100
//   cantidad        8 bits: 60 (para versiones 1..9 en modo byte)
//   contenido     480 bits: los 60 bytes de text_in
//   terminador      4 bits: 0000
//   relleno        16 bits: EC 11
// Total: 512 bits. Tras el terminador ya hay alineacion a un byte.
//
// start: pulso cuando busy=0; captura text_in.
// done: pulso un ciclo DESPUES de aceptar start.
// data_out se borra al aceptar start y se publica completo con done.
// Ignora start durante busy. Reset asincrono activo en alto.
// No valida Base64: QR en modo byte transporta los 60 bytes recibidos.
//
// Pendientes en otros modulos: Reed-Solomon, intercalado, patrones, mascara
// y matriz. Este archivo por si solo no produce un QR escaneable.

module qr_data_encode (
    input  wire         clk,
    input  wire         reset,
    input  wire         start,
    input  wire [479:0] text_in,

    output reg  [511:0] data_out,
    output reg          busy,
    output reg          done
);

    reg [479:0] text_reg;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            text_reg <= 480'd0;
            data_out <= 512'd0;
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;

            if (busy) begin
                data_out <= {4'b0100, 8'd60, text_reg, 4'b0000, 8'hEC, 8'h11};
                busy <= 1'b0;
                done <= 1'b1;
            end else if (start) begin
                text_reg <= text_in;
                data_out <= 512'd0;
                busy <= 1'b1;
            end
        end
    end

endmodule
