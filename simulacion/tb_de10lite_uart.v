`timescale 1ns/1ps

// Banco de pruebas del protocolo UART de de10lite_top (SOLO simulacion).
// Hace lo que hara la ESP32: envia tramas bit a bit por UART_RX a 115200
// baudios y decodifica las respuestas que salen por UART_TX.
//
// 1. 'E' + "Hola FPGA 123456" -> 'C' + Base64, igual a una instancia
//    independiente de crypto_qr_controller (nonce contador 0); QR en pantalla.
// 2. 'D' + ese Base64           -> 'P' 'K' + "Hola FPGA 123456".
// 3. 'D' + un caracter cambiado -> 'P' 'T' + 16 ceros.
// 4. 'D' + caracter invalido    -> 'P' 'B' + 16 ceros.
// 5. Byte basura y trama 'E' incompleta: sin respuesta; tras el tiempo
//    limite, una trama valida funciona (nonce contador 1).
// 6. KEY1 tambien envia 'C' (mensaje de interruptores, nonce contador 2).
// +LOG=archivo guarda los textos Base64 recibidos.

module tb_de10lite_uart;

    localparam [127:0] KEY_T  = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [63:0]  PREFIX = 64'hde10_11fe_0000_0000;
    localparam integer BIT_NS = 434 * 20;      // 115200 baudios con 50 MHz

    reg        clk = 1'b0;
    reg  [1:0] KEY = 2'b11;
    reg  [9:0] SW  = 10'h155;
    reg        UART_RX = 1'b1;
    wire       UART_TX;
    wire [9:0] LEDR;
    wire [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire [3:0] VGA_R, VGA_G, VGA_B;
    wire       VGA_HS, VGA_VS;

    always #10 clk = ~clk;

    de10lite_top #(.DEBOUNCE_CYCLES(8), .POR_BITS(4), .UART_TIMEOUT(20000)) dut (
        .MAX10_CLK1_50(clk), .KEY(KEY), .SW(SW), .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
        .UART_RX(UART_RX), .UART_TX(UART_TX)
    );

    // Referencia independiente del cifrado
    reg          ref_reset = 1'b1, ref_start = 1'b0;
    reg  [95:0]  ref_nonce;
    reg  [127:0] ref_pt;
    wire [351:0] ref_packet;
    wire [479:0] ref_text;
    wire [1088:0] ref_matrix;
    wire [2:0]   ref_mask;
    wire         ref_busy, ref_done;

    crypto_qr_controller referencia (
        .clk(clk), .reset(ref_reset), .start(ref_start),
        .key(KEY_T), .nonce(ref_nonce), .plaintext(ref_pt),
        .packet_out(ref_packet), .text_out(ref_text), .matrix_out(ref_matrix),
        .mask_out(ref_mask), .busy(ref_busy), .done(ref_done)
    );

    task run_reference(input [95:0] n, input [127:0] p);
        begin
            ref_nonce = n; ref_pt = p;
            @(negedge clk) ref_start = 1'b1;
            @(negedge clk) ref_start = 1'b0;
            wait (ref_done);
            @(negedge clk);
        end
    endtask

    integer errors = 0;
    task fail(input [8*90-1:0] msg);
        begin
            errors = errors + 1;
            $display("FAIL: %0s", msg);
        end
    endtask

    // ------------------------------------------------------------------
    // Envio (lado ESP32)
    // ------------------------------------------------------------------
    task send_byte(input [7:0] b);
        integer i;
        begin
            UART_RX = 1'b0; #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin UART_RX = b[i]; #(BIT_NS); end
            UART_RX = 1'b1; #(BIT_NS);
        end
    endtask

    task send_E(input [127:0] p);
        integer i;
        begin
            send_byte("E");
            for (i = 15; i >= 0; i = i - 1) send_byte(p[8*i +: 8]);
        end
    endtask

    task send_D(input [479:0] t);
        integer i;
        begin
            send_byte("D");
            for (i = 59; i >= 0; i = i - 1) send_byte(t[8*i +: 8]);
        end
    endtask

    // ------------------------------------------------------------------
    // Recepcion (lado ESP32): decodifica UART_TX
    // ------------------------------------------------------------------
    reg [7:0] rx_mem [0:1023];
    integer   rx_count = 0;
    reg [7:0] rx_b;
    integer   k;

    initial begin
        #(200);
        forever begin
            @(negedge UART_TX);
            #(BIT_NS + BIT_NS/2);
            for (k = 0; k < 8; k = k + 1) begin rx_b[k] = UART_TX; #(BIT_NS); end
            if (UART_TX !== 1'b1) fail("bit de parada incorrecto en UART_TX");
            rx_mem[rx_count] = rx_b;
            rx_count = rx_count + 1;
        end
    end

    // Espera n bytes nuevos (desde 'from') con limite de tiempo
    task wait_bytes(input integer from, input integer n);
        integer t;
        begin
            t = 0;
            while (rx_count < from + n && t < 200000) begin #(1000); t = t + 1; end
            if (rx_count < from + n) fail("no llego la respuesta completa");
            #(BIT_NS * 30);   // margen: no deben llegar bytes extra
            if (rx_count != from + n) begin
                $display("  bytes recibidos %0d, esperados %0d", rx_count - from, n);
                fail("cantidad de bytes de respuesta incorrecta");
            end
        end
    endtask

    function [479:0] rx_text(input integer from);   // 60 bytes desde 'from'
        integer i;
        begin
            for (i = 0; i < 60; i = i + 1) rx_text[479 - 8*i -: 8] = rx_mem[from + i];
        end
    endfunction

    function [127:0] rx_block(input integer from);  // 16 bytes desde 'from'
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1) rx_block[127 - 8*i -: 8] = rx_mem[from + i];
        end
    endfunction

    task expect_C(input integer from, input [8*20-1:0] tag);
        begin
            wait_bytes(from, 61);
            if (rx_mem[from] !== "C") fail({tag, ": la respuesta no empieza con C"});
            if (rx_text(from + 1) !== ref_text) fail({tag, ": Base64 distinto de la referencia"});
            if (dut.matrix !== ref_matrix)     fail({tag, ": QR distinto de la referencia"});
            if (LEDR[1] !== 1'b1)              fail({tag, ": LEDR1 sin QR valido"});
        end
    endtask

    task expect_P(input integer from, input [7:0] st, input [127:0] pt, input [8*20-1:0] tag);
        begin
            wait_bytes(from, 18);
            if (rx_mem[from] !== "P")      fail({tag, ": la respuesta no empieza con P"});
            if (rx_mem[from + 1] !== st)   begin
                $display("  estado recibido '%c'", rx_mem[from + 1]);
                fail({tag, ": estado incorrecto"});
            end
            if (rx_block(from + 2) !== pt) fail({tag, ": texto descifrado incorrecto"});
        end
    endtask

    reg [479:0] text0, alt;
    reg [8*256-1:0] log_name;
    integer log_fd, base;

    initial begin
        log_fd = 0;
        if ($value$plusargs("LOG=%s", log_name)) log_fd = $fopen(log_name, "w");

        repeat (5) @(negedge clk);
        ref_reset = 1'b0;
        repeat (50) @(negedge clk);

        // 1. Cifrar por UART
        base = rx_count;
        fork
            send_E("Hola FPGA 123456");
            run_reference({PREFIX, 32'd0}, "Hola FPGA 123456");
        join
        expect_C(base, "E1");
        text0 = rx_text(base + 1);
        $display("C 0: %s", text0);
        if (log_fd) $fdisplay(log_fd, "%s", text0);

        // 2. Descifrar el mismo texto
        base = rx_count;
        send_D(text0);
        expect_P(base, "K", "Hola FPGA 123456", "D valido");
        if (LEDR[4:2] !== 3'b001) fail("LEDR2 deberia indicar descifrado correcto");

        // 3. Un caracter cambiado por otro valido
        alt = text0;
        alt[479 - 8*20 -: 8] = (text0[479 - 8*20 -: 8] == "A") ? "B" : "A";
        base = rx_count;
        send_D(alt);
        expect_P(base, "T", 128'd0, "D alterado");
        if (LEDR[4:2] !== 3'b010) fail("LEDR3 deberia indicar etiqueta incorrecta");

        // 4. Caracter fuera del alfabeto
        alt = text0;
        alt[479 - 8*5 -: 8] = "*";
        base = rx_count;
        send_D(alt);
        expect_P(base, "B", 128'd0, "D base64");
        if (LEDR[4:2] !== 3'b100) fail("LEDR4 deberia indicar Base64 invalido");

        // 5. Basura y trama incompleta: sin respuesta
        base = rx_count;
        send_byte("Z");
        send_byte("E"); send_byte("a"); send_byte("b"); send_byte("c");
        #(20000 * 40 * 2);                 // mas que UART_TIMEOUT (ciclos de 40 ns)
        if (rx_count != base) fail("hubo respuesta a basura o trama incompleta");
        if (dut.msg_count !== 32'd1) fail("una trama incompleta inicio un cifrado");
        fork
            send_E("Segundo mensaje!");
            run_reference({PREFIX, 32'd1}, "Segundo mensaje!");
        join
        expect_C(base, "E2");
        $display("C 1: %s", rx_text(base + 1));
        if (log_fd) $fdisplay(log_fd, "%s", rx_text(base + 1));

        // 6. KEY1 tambien responde por UART
        base = rx_count;
        fork
            begin
                @(negedge clk) KEY[1] = 1'b0;
                repeat (40) @(negedge clk);
                KEY[1] = 1'b1;
            end
            run_reference({PREFIX, 32'd2}, "DE10-Lite SW=155");
        join
        expect_C(base, "KEY1");
        $display("C 2: %s", rx_text(base + 1));
        if (log_fd) $fdisplay(log_fd, "%s", rx_text(base + 1));
        if (HEX0 !== 8'b10100100) fail("HEX0 deberia mostrar 2");

        if (log_fd) $fclose(log_fd);
        if (errors == 0)
            $display("PASS: UART 115200; E->C x2, D->P (K, T, B), basura/trama incompleta descartadas, KEY1->C; todo igual a la referencia.");
        else
            $display("FALLO: %0d errores", errors);
        $finish;
    end

endmodule
