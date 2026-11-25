`timescale 1ns/1ps

// Muestra la matriz QR 33x33 en un monitor VGA 640x480 a 60 Hz.
//
// El pixel avanza a 25 MHz. Con PIX_DIV=1 el reloj ya es de 25 MHz y avanza
// cada ciclo (configuracion del top). Con PIX_DIV=2 el reloj es de 50 MHz y
// avanza un ciclo si, uno no. 25 MHz esta dentro de la tolerancia de los
// monitores para el modo 640x480 (nominal 25.175 MHz).
//
// Simbolo: 33 modulos + 4 de margen blanco por lado = 41 modulos, de
// SCALE pixeles cada uno (11 -> 451x451 pixeles), centrado en pantalla.
//   valid=1: margen y modulos claros en blanco, modulos oscuros en negro.
//   valid=0: el cuadro se dibuja gris (todavia no hay QR).
// Fuera del cuadro: fondo gris oscuro.
//
// Lectura de la matriz: (fila,columna) = matrix_in[1088-(fila*33+columna)],
// 1 = negro. Mismo convenio que crypto_qr_controller / qr_generator.
//
// Salidas registradas, con 3 etapas de retardo iguales para color y sincronia.
// HS y VS son activas en bajo (convencion 640x480@60).

module vga_qr_display #(
    parameter integer SCALE   = 11,
    parameter integer PIX_DIV = 2        // 1: clk de 25 MHz, 2: clk de 50 MHz
)(
    input  wire          clk,
    input  wire          reset,      // asincrono, activo en alto
    input  wire [1088:0] matrix_in,
    input  wire          valid,

    output reg  [3:0]    vga_r,
    output reg  [3:0]    vga_g,
    output reg  [3:0]    vga_b,
    output reg           vga_hs,
    output reg           vga_vs
);

    // Temporizacion 640x480@60
    localparam integer H_VISIBLE = 640, H_FRONT = 16, H_SYNC = 96, H_BACK = 48;
    localparam integer V_VISIBLE = 480, V_FRONT = 10, V_SYNC = 2,  V_BACK = 33;
    localparam integer H_TOTAL = H_VISIBLE + H_FRONT + H_SYNC + H_BACK; // 800
    localparam integer V_TOTAL = V_VISIBLE + V_FRONT + V_SYNC + V_BACK; // 525

    localparam integer QR_SIZE  = 33;
    localparam integer QUIET    = 4;
    localparam integer FULL     = QR_SIZE + 2*QUIET;          // 41 modulos
    localparam integer SIDE_PX  = FULL * SCALE;               // 451 pixeles
    localparam integer X0       = (H_VISIBLE - SIDE_PX) / 2;  // 94
    localparam integer Y0       = (V_VISIBLE - SIDE_PX) / 2;  // 14

    // Habilitador de pixel a 25 MHz
    reg pix_toggle;
    always @(posedge clk or posedge reset)
        if (reset) pix_toggle <= 1'b0;
        else       pix_toggle <= ~pix_toggle;
    wire pix_en = (PIX_DIV == 1) ? 1'b1 : pix_toggle;

    // Etapa 0: contadores de pantalla y de modulo (incrementales, sin division)
    reg [9:0] h, v;
    reg       qx_on, qy_on;              // dentro del cuadro de 41x41
    reg [3:0] sx, sy;                    // pixel dentro del modulo (0..SCALE-1)
    reg [5:0] mx, my;                    // modulo, incluyendo margen (0..40)

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            h <= 10'd0;  v <= 10'd0;
            qx_on <= 1'b0; qy_on <= 1'b0;
            sx <= 4'd0; sy <= 4'd0; mx <= 6'd0; my <= 6'd0;
        end else if (pix_en) begin
            // Horizontal: los registros describen el pixel h tras el flanco.
            if (h == H_TOTAL-1) h <= 10'd0;
            else                h <= h + 10'd1;

            if (h == X0-1) begin
                qx_on <= 1'b1; sx <= 4'd0; mx <= 6'd0;
            end else if (qx_on) begin
                if (sx == SCALE-1) begin
                    sx <= 4'd0;
                    if (mx == FULL-1) qx_on <= 1'b0;
                    else              mx <= mx + 6'd1;
                end else
                    sx <= sx + 4'd1;
            end

            // Vertical: avanza al terminar cada linea.
            if (h == H_TOTAL-1) begin
                if (v == V_TOTAL-1) v <= 10'd0;
                else                v <= v + 10'd1;

                if (v == Y0-1) begin
                    qy_on <= 1'b1; sy <= 4'd0; my <= 6'd0;
                end else if (qy_on) begin
                    if (sy == SCALE-1) begin
                        sy <= 4'd0;
                        if (my == FULL-1) qy_on <= 1'b0;
                        else              my <= my + 6'd1;
                    end else
                        sy <= sy + 4'd1;
                end
            end
        end
    end

    // Etapa 1: zona y coordenadas dentro del simbolo
    reg        act1, hs1, vs1, sq1, code1;
    reg [5:0]  row1, col1;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            act1 <= 1'b0; hs1 <= 1'b1; vs1 <= 1'b1; sq1 <= 1'b0; code1 <= 1'b0;
            row1 <= 6'd0; col1 <= 6'd0;
        end else if (pix_en) begin
            act1  <= (h < H_VISIBLE) && (v < V_VISIBLE);
            hs1   <= ~((h >= H_VISIBLE+H_FRONT) && (h < H_VISIBLE+H_FRONT+H_SYNC));
            vs1   <= ~((v >= V_VISIBLE+V_FRONT) && (v < V_VISIBLE+V_FRONT+V_SYNC));
            sq1   <= qx_on && qy_on;
            code1 <= qx_on && qy_on &&
                     (mx >= QUIET) && (mx < QUIET+QR_SIZE) &&
                     (my >= QUIET) && (my < QUIET+QR_SIZE);
            row1  <= my - QUIET;
            col1  <= mx - QUIET;
        end
    end

    // Etapa 2: selecciona la fila de 33 bits (fila 0 = bits [1088:1056])
    reg        act2, hs2, vs2, sq2, code2;
    reg [5:0]  col2;
    reg [32:0] row_bits2;
    wire [10:0] row_base = 11'd1088 - ({5'd0, row1} * 11'd33);
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            act2 <= 1'b0; hs2 <= 1'b1; vs2 <= 1'b1; sq2 <= 1'b0; code2 <= 1'b0;
            col2 <= 6'd0; row_bits2 <= 33'd0;
        end else if (pix_en) begin
            act2 <= act1; hs2 <= hs1; vs2 <= vs1; sq2 <= sq1; code2 <= code1;
            col2 <= col1;
            row_bits2 <= code1 ? matrix_in[row_base -: 33] : 33'd0;
        end
    end

    // Etapa 3: color final (columna 0 = bit 32 de la fila)
    wire dark = code2 && row_bits2[6'd32 - col2];
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            vga_r <= 4'd0; vga_g <= 4'd0; vga_b <= 4'd0;
            vga_hs <= 1'b1; vga_vs <= 1'b1;
        end else if (pix_en) begin
            vga_hs <= hs2;
            vga_vs <= vs2;
            if (!act2) begin
                {vga_r, vga_g, vga_b} <= 12'h000;     // borrado obligatorio
            end else if (sq2 && valid) begin
                {vga_r, vga_g, vga_b} <= dark ? 12'h000 : 12'hFFF;
            end else if (sq2) begin
                {vga_r, vga_g, vga_b} <= 12'h888;     // aun sin QR
            end else begin
                {vga_r, vga_g, vga_b} <= 12'h224;     // fondo
            end
        end
    end

endmodule
