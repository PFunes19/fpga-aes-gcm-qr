`timescale 1ns/1ps

// Puerto de comandos por UART entre la ESP32 y la FPGA.
// Usa uart_rx y uart_tx (8N1) sin modificarlos.
//
// TRAMAS QUE RECIBE (ESP32 -> FPGA), bytes en este orden:
//   'E' + 16 bytes     cifrar estos 16 bytes          (17 bytes en total)
//   'D' + 60 bytes     descifrar este texto Base64    (61 bytes en total)
// Un byte inicial distinto de 'E' o 'D' se descarta.
// Si dentro de una trama pasan TIMEOUT_CYCLES sin recibir un byte, o llega
// un byte con error de parada, la trama incompleta se descarta.
//
// Hacia el top:
//   cmd_valid      1 cuando hay una trama completa pendiente; se mantiene
//                  hasta cmd_ack. Mientras este pendiente, las tramas nuevas
//                  se reciben completas pero se descartan (la ESP32 debe
//                  esperar la respuesta antes de enviar otra solicitud).
//   cmd_type       'E' o 'D'.
//   cmd_payload    'E': bytes en [127:0], primero en [127:120].
//                  'D': caracteres en [479:0], primero en [479:472].
//
// RESPUESTAS (FPGA -> ESP32): el top entrega hasta 61 bytes alineados a la
// izquierda en resp_data (primer byte en [487:480]) y su cantidad en
// resp_len, con un pulso de resp_start cuando resp_busy=0.
// resp_busy baja cuando el ultimo bit de parada ya salio.

module uart_command_port #(
    parameter integer CLK_FREQ       = 50000000,
    parameter integer BAUD_RATE      = 115200,
    parameter integer TIMEOUT_CYCLES = 2500000     // 50 ms a 50 MHz
)(
    input  wire          clk,
    input  wire          reset,
    input  wire          rx,
    output wire          tx,

    output reg           cmd_valid,
    output reg  [7:0]    cmd_type,
    output reg  [479:0]  cmd_payload,
    input  wire          cmd_ack,

    input  wire          resp_start,
    input  wire [6:0]    resp_len,
    input  wire [487:0]  resp_data,
    output reg           resp_busy
);

    // ------------------------------------------------------------------
    // Recepcion
    // ------------------------------------------------------------------
    wire [7:0] rx_byte;
    wire       rx_valid, rx_ferr;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) receptor (
        .clk(clk), .reset(reset), .rx(rx),
        .data_out(rx_byte), .data_valid(rx_valid), .frame_error(rx_ferr)
    );

    reg         in_frame;
    reg  [7:0]  frame_type;
    reg  [6:0]  remaining;
    reg  [479:0] assembly;
    reg  [31:0] idle_count;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            in_frame    <= 1'b0;
            frame_type  <= 8'd0;
            remaining   <= 7'd0;
            assembly    <= 480'd0;
            idle_count  <= 32'd0;
            cmd_valid   <= 1'b0;
            cmd_type    <= 8'd0;
            cmd_payload <= 480'd0;
        end else begin
            if (cmd_ack) cmd_valid <= 1'b0;

            if (!in_frame) begin
                if (rx_valid && (rx_byte == "E" || rx_byte == "D")) begin
                    in_frame   <= 1'b1;
                    frame_type <= rx_byte;
                    remaining  <= (rx_byte == "E") ? 7'd16 : 7'd60;
                    assembly   <= 480'd0;
                    idle_count <= 32'd0;
                end
            end else begin
                if (rx_ferr || idle_count == TIMEOUT_CYCLES-1) begin
                    in_frame <= 1'b0;                  // trama descartada
                end else if (rx_valid) begin
                    idle_count <= 32'd0;
                    assembly   <= {assembly[471:0], rx_byte};
                    remaining  <= remaining - 7'd1;
                    if (remaining == 7'd1) begin
                        in_frame <= 1'b0;
                        if (!cmd_valid || cmd_ack) begin
                            cmd_valid   <= 1'b1;
                            cmd_type    <= frame_type;
                            cmd_payload <= {assembly[471:0], rx_byte};
                        end
                    end
                end else
                    idle_count <= idle_count + 32'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Transmision
    // ------------------------------------------------------------------
    reg  [487:0] tx_buffer;
    reg  [6:0]   tx_left;
    wire         tx_busy;
    // uart_tx acepta tx_start solo con busy=0; busy sube en el flanco
    // siguiente, asi que un byte por flanco libre es seguro.
    wire         tx_go = resp_busy && (tx_left != 7'd0) && !tx_busy;

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) transmisor (
        .clk(clk), .reset(reset), .tx_start(tx_go),
        .data_in(tx_buffer[487:480]), .tx(tx), .busy(tx_busy)
    );

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            tx_buffer <= 488'd0;
            tx_left   <= 7'd0;
            resp_busy <= 1'b0;
        end else if (!resp_busy) begin
            if (resp_start && resp_len != 7'd0) begin
                tx_buffer <= resp_data;
                tx_left   <= resp_len;
                resp_busy <= 1'b1;
            end
        end else if (tx_go) begin
            tx_buffer <= {tx_buffer[479:0], 8'd0};
            tx_left   <= tx_left - 7'd1;
        end else if (tx_left == 7'd0 && !tx_busy) begin
            resp_busy <= 1'b0;
        end
    end

endmodule
