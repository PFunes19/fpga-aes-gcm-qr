`timescale 1ns/1ps

// SOLO SIMULACION: envuelve asic_top con los puertos de de10lite_top para
// reutilizar los bancos de prueba de la FPGA sin cambiarlos.
// Divide 50 MHz / 2 y genera el reset de encendido aqui afuera, como lo
// haria el circuito que rodea al chip.
// Compilar con ..\asic\asic_top.v y los .v de quartus\ EXCEPTO de10lite_top.v.

module de10lite_top #(
    parameter [127:0] DEMO_KEY        = 128'h000102030405060708090a0b0c0d0e0f,
    parameter [63:0]  NONCE_PREFIX    = 64'hde10_11fe_0000_0000,
    parameter integer DEBOUNCE_CYCLES = 250000,
    parameter integer POR_BITS        = 20,
    parameter integer UART_BAUD       = 115200,
    parameter integer UART_TIMEOUT    = 1250000
)(
    input  wire        MAX10_CLK1_50,
    input  wire [1:0]  KEY,
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR,
    output wire [7:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    output wire [3:0]  VGA_R, VGA_G, VGA_B,
    output wire        VGA_HS, VGA_VS,
    input  wire        UART_RX,
    output wire        UART_TX
);
    reg clk25 = 1'b0;
    always @(posedge MAX10_CLK1_50) clk25 <= ~clk25;

    reg [POR_BITS-1:0] por_cnt = {POR_BITS{1'b0}};
    wire por_done = &por_cnt;
    always @(posedge clk25) if (!por_done) por_cnt <= por_cnt + 1'b1;

    asic_top #(
        .DEMO_KEY(DEMO_KEY), .NONCE_PREFIX(NONCE_PREFIX),
        .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES), .UART_BAUD(UART_BAUD),
        .UART_TIMEOUT(UART_TIMEOUT)
    ) chip (
        .clk(clk25), .rst_n(por_done & KEY[0]),
        .KEY(KEY), .SW(SW), .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
        .UART_RX(UART_RX), .UART_TX(UART_TX)
    );

    // Senales internas que los bancos de prueba leen como dut.<nombre>
    wire [1088:0] matrix    = chip.matrix;
    wire [31:0]   msg_count = chip.msg_count;
endmodule
