`timescale 1ns/1ps

// Banco de pruebas de de10lite_top (SOLO simulacion).
//
// 1. Pulsa KEY1 con SW=2A5 y compara paquete, texto, matriz y mascara con
//    una instancia independiente de crypto_qr_controller alimentada con el
//    mensaje y nonce esperados ("DE10-Lite SW=2A5", contador 0).
// 2. Reconstruye un cuadro VGA completo usando solo VGA_HS/VGA_VS/RGB:
//    comprueba 800 pixeles por linea, HS de 96, 525 lineas, VS de 2 lineas,
//    y los 640x480 pixeles visibles contra la matriz esperada.
// 3. Segunda pulsacion con SW=3FF: el nonce debe avanzar a 1.
// 4. Reset con KEY0: QR invalido y contador a 0.
// Opcional: +BMP=archivo.bmp guarda el cuadro capturado.

module tb_de10lite_top;

    localparam [127:0] KEY_T  = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [63:0]  PREFIX = 64'hde10_11fe_0000_0000;

    reg        clk = 1'b0;
    reg  [1:0] KEY = 2'b11;
    reg  [9:0] SW  = 10'h2A5;
    wire [9:0] LEDR;
    wire [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire [3:0] VGA_R, VGA_G, VGA_B;
    wire       VGA_HS, VGA_VS;

    always #10 clk = ~clk;   // 50 MHz

    de10lite_top #(.DEBOUNCE_CYCLES(8), .POR_BITS(4)) dut (
        .MAX10_CLK1_50(clk), .KEY(KEY), .SW(SW), .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .UART_RX(1'b1), .UART_TX()
    );

    // Referencia independiente
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

    integer errors = 0;

    task fail(input [8*80-1:0] msg);
        begin
            errors = errors + 1;
            $display("FAIL: %0s", msg);
        end
    endtask

    task run_reference(input [95:0] n, input [127:0] p);
        begin
            ref_nonce = n; ref_pt = p;
            @(negedge clk) ref_start = 1'b1;
            @(negedge clk) ref_start = 1'b0;
            wait (ref_done);
            @(negedge clk);
        end
    endtask

    task press_key1;
        begin
            @(negedge clk) KEY[1] = 1'b0;
            repeat (40) @(negedge clk);
            KEY[1] = 1'b1;
        end
    endtask

    task wait_dut_done;
        integer t;
        begin
            t = 0;
            while (!dut.enc_done && t < 100000) begin @(posedge clk); t = t + 1; end
            if (!dut.enc_done) fail("el top no termino");
            // LEDR/HEX se actualizan un ciclo de 25 MHz despues de done
            repeat (4) @(negedge clk);
        end
    endtask

    task compare(input [8*20-1:0] tag);
        begin
            if (dut.packet !== ref_packet) fail({tag, ": paquete distinto"});
            if (dut.text   !== ref_text)   fail({tag, ": texto distinto"});
            if (dut.matrix !== ref_matrix) fail({tag, ": matriz distinta"});
            if (dut.mask   !== ref_mask)   fail({tag, ": mascara distinta"});
            if (LEDR[1] !== 1'b1)          fail({tag, ": LEDR1 no indica QR valido"});
        end
    endtask

    // ------------------------------------------------------------------
    // Captura VGA desde los pines. Los pines cambian en flancos con
    // pix_en=1; se muestrea en el flanco de bajada siguiente (sin usar
    // los contadores internos del modulo VGA).
    // ------------------------------------------------------------------
    reg [11:0] frame [0:479][0:639];
    reg        sample_phase = 1'b0;

    task capture_frame;
        integer x, y, k, line_len, hs_len, lines, vs_lines;
        reg prev_hs, prev_vs, in_vs;
        begin
            // Esperar el flanco de bajada de VS
            @(negedge VGA_VS);
            // Alinear con el flanco de bajada de HS (inicio de linea)
            y = -1; lines = 0; vs_lines = 0;
            prev_hs = 1'b0;
            line_len = 0; hs_len = 0; x = 0;
            in_vs = 1'b1;
            prev_vs = 1'b0;
            // Recorre 525 lineas de 800 pixeles a 25 MHz (2 ciclos por pixel)
            // Muestreo: un pixel cada dos ciclos, en fase con el cambio de pines.
            @(negedge VGA_HS);
            for (k = 0; k < 800*525; k = k + 1) begin
                // muestra en el centro del pixel
                @(negedge clk); @(negedge clk);
                if (k % 800 == 0) begin
                    lines = lines + 1;
                    if (VGA_VS == 1'b0) vs_lines = vs_lines + 1;
                end
                x = (k % 800) - (96 + 48);
                // k=0 es el flanco de HS de la linea 490 (inicio de VS);
                // la linea visible 0 empieza 34 lineas despues de ese flanco.
                y = (k / 800) - 34;
                if ((k % 800) < 96 && VGA_HS !== 1'b0)
                    fail("HS no esta en bajo durante 96 pixeles");
                if ((k % 800) >= 96 && VGA_HS !== 1'b1)
                    fail("HS en bajo fuera de su pulso");
                if (x >= 0 && x < 640 && y >= 0 && y < 480)
                    frame[y][x] = {VGA_R, VGA_G, VGA_B};
                else if ({VGA_R, VGA_G, VGA_B} !== 12'h000)
                    fail("color distinto de negro en el borrado");
            end
            if (vs_lines != 2) begin
                $display("vs_lines=%0d", vs_lines);
                fail("VS no dura 2 lineas");
            end
        end
    endtask

    task check_frame(input [1088:0] m, input expect_valid);
        integer x, y, mx, my, bad;
        reg [11:0] want;
        begin
            bad = 0;
            for (y = 0; y < 480; y = y + 1)
                for (x = 0; x < 640; x = x + 1) begin
                    if (x >= 94 && x < 94+451 && y >= 14 && y < 14+451) begin
                        mx = (x - 94) / 11 - 4;
                        my = (y - 14) / 11 - 4;
                        if (!expect_valid)
                            want = 12'h888;
                        else if (mx >= 0 && mx < 33 && my >= 0 && my < 33 &&
                                 m[1088 - (my*33 + mx)])
                            want = 12'h000;
                        else
                            want = 12'hFFF;
                    end else
                        want = 12'h224;
                    if (frame[y][x] !== want) begin
                        if (bad < 5)
                            $display("  pixel (%0d,%0d) = %h, esperado %h", x, y, frame[y][x], want);
                        bad = bad + 1;
                    end
                end
            if (bad != 0) begin
                $display("  %0d pixeles distintos", bad);
                fail("cuadro VGA distinto del esperado");
            end
        end
    endtask

    task write_bmp(input [8*256-1:0] fname);
        integer fd, x, y, i;
        reg [31:0] size;
        reg [11:0] c;
        begin
            fd = $fopen(fname, "wb");
            size = 54 + 640*480*3;
            $fwrite(fd, "BM");
            for (i = 0; i < 4; i = i + 1) $fwrite(fd, "%c", size[8*i +: 8]);
            $fwrite(fd, "%c%c%c%c", 8'd0, 8'd0, 8'd0, 8'd0);
            $fwrite(fd, "%c%c%c%c", 8'd54, 8'd0, 8'd0, 8'd0);
            $fwrite(fd, "%c%c%c%c", 8'd40, 8'd0, 8'd0, 8'd0);
            $fwrite(fd, "%c%c%c%c", 8'h80, 8'h02, 8'd0, 8'd0);   // 640
            $fwrite(fd, "%c%c%c%c", 8'hE0, 8'h01, 8'd0, 8'd0);   // 480
            $fwrite(fd, "%c%c%c%c", 8'd1, 8'd0, 8'd24, 8'd0);
            for (i = 0; i < 24; i = i + 1) $fwrite(fd, "%c", 8'd0);
            for (y = 479; y >= 0; y = y - 1)
                for (x = 0; x < 640; x = x + 1) begin
                    c = frame[y][x];
                    $fwrite(fd, "%c%c%c", {c[3:0], c[3:0]}, {c[7:4], c[7:4]}, {c[11:8], c[11:8]});
                end
            $fclose(fd);
        end
    endtask

    reg [8*256-1:0] bmp_name;

    initial begin
        // Arranque: reset de encendido interno
        repeat (5) @(negedge clk);
        ref_reset = 1'b0;
        repeat (40) @(negedge clk);
        if (LEDR[1] !== 1'b0) fail("QR valido antes de pulsar");
        if (HEX0 !== 8'hBF)   fail("HEX0 deberia mostrar '-'");

        // Cuadro sin QR: el cuadro central debe verse gris
        capture_frame;
        check_frame(1089'd0, 1'b0);

        // 1. Primera pulsacion, SW=2A5, nonce contador 0
        fork
            press_key1;
            run_reference({PREFIX, 32'd0}, "DE10-Lite SW=2A5");
        join
        wait_dut_done;
        compare("mensaje 0");
        if (HEX0 !== 8'b11000000) fail("HEX0 deberia mostrar 0");
        $display("Texto Base64 0: %s", dut.text);

        capture_frame;
        check_frame(ref_matrix, 1'b1);
        if ($value$plusargs("BMP=%s", bmp_name)) begin
            write_bmp(bmp_name);
            $display("Cuadro guardado en %0s", bmp_name);
        end

        // Rebotes: muchas transiciones cortas no deben iniciar nada
        repeat (10) begin
            @(negedge clk) KEY[1] = 1'b0;
            repeat (3) @(negedge clk);
            KEY[1] = 1'b1;
            repeat (3) @(negedge clk);
        end
        repeat (50) @(negedge clk);
        if (dut.enc_busy !== 1'b0 || dut.msg_count !== 32'd1)
            fail("un rebote corto inicio una solicitud");

        // 2. Segunda pulsacion, SW=3FF, contador 1
        SW = 10'h3FF;
        repeat (5) @(negedge clk);
        fork
            press_key1;
            run_reference({PREFIX, 32'd1}, "DE10-Lite SW=3FF");
        join
        wait_dut_done;
        compare("mensaje 1");
        if (HEX0 !== 8'b11111001) fail("HEX0 deberia mostrar 1");
        $display("Texto Base64 1: %s", dut.text);

        // Mantener KEY1 pulsado no genera mas solicitudes.
        // Antes, esperar que termine la respuesta UART 'C' (LEDR0 = ocupado).
        wait (LEDR[0] == 1'b0);
        @(negedge clk) KEY[1] = 1'b0;
        repeat (100000) @(negedge clk);
        KEY[1] = 1'b1;
        repeat (50) @(negedge clk);
        if (dut.msg_count !== 32'd3) fail("mantener KEY1 no debe repetir solicitudes");
        if (LEDR[1] !== 1'b1)        fail("la solicitud del boton mantenido no termino");

        // 3. Reset con KEY0
        @(negedge clk) KEY[0] = 1'b0;
        repeat (10) @(negedge clk);
        KEY[0] = 1'b1;
        repeat (10) @(negedge clk);
        if (LEDR[1] !== 1'b0 || dut.msg_count !== 32'd0 || dut.matrix !== 1089'd0)
            fail("KEY0 no reinicio el sistema");

        if (errors == 0)
            $display("PASS: top DE10-Lite; 2 mensajes iguales a la referencia, cuadros VGA 640x480 completos (sin QR y con QR), sincronias, antirrebote, nonce incremental y reset.");
        else
            $display("FALLO: %0d errores", errors);
        $finish;
    end

endmodule
