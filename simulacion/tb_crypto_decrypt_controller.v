`timescale 1ns/1ps

// Banco de pruebas de crypto_decrypt_controller (SOLO simulacion).
// Vectores: crypto_base64_vectors.txt (cryptography/OpenSSL + base64 Python)
//   clave nonce original cifrado etiqueta texto_base64(hex)
// Por vector: descifrado valido, caracter alterado (etiqueta incorrecta),
// caracter invalido (Base64 invalido) y clave equivocada.
// Ademas: start ignorado durante busy, salidas borradas y reset a mitad.
//
// vvp ... +VECTORS=crypto_base64_vectors.txt

module tb_crypto_decrypt_controller;

    reg          clk = 1'b0, reset = 1'b1, start = 1'b0;
    reg  [127:0] key;
    reg  [479:0] text;
    wire [127:0] plaintext;
    wire [95:0]  nonce;
    wire [1:0]   status;
    wire         busy, done;

    always #10 clk = ~clk;

    crypto_decrypt_controller dut (
        .clk(clk), .reset(reset), .start(start), .key(key), .text_in(text),
        .plaintext_out(plaintext), .nonce_out(nonce), .status_out(status),
        .busy(busy), .done(done)
    );

    integer errors = 0, checks = 0;
    integer cycles;

    task run(input [127:0] k, input [479:0] t);
        begin
            key = k; text = t;
            @(negedge clk) start = 1'b1;
            @(negedge clk) start = 1'b0;
            // Cambiar las entradas durante busy no debe afectar
            key = ~k; text = ~t;
            if (!busy) begin errors = errors + 1; $display("FAIL: busy no subio"); end
            if (plaintext !== 128'd0 || status !== 2'd0)
                begin errors = errors + 1; $display("FAIL: salida no borrada al iniciar"); end
            cycles = 1;
            // start durante busy se ignora
            start = 1'b1; @(negedge clk); start = 1'b0; cycles = cycles + 1;
            while (!done && cycles < 1000) begin @(negedge clk); cycles = cycles + 1; end
            if (!done) begin errors = errors + 1; $display("FAIL: sin done"); end
        end
    endtask

    task expect_result(input [1:0] st, input [127:0] pt, input [95:0] n, input [8*24-1:0] what);
        begin
            checks = checks + 1;
            if (status !== st || plaintext !== pt || (st == 2'd0 && nonce !== n) || busy !== 1'b0) begin
                errors = errors + 1;
                $display("FAIL %0s: status=%0d pt=%h nonce=%h (esperado %0d %h %h)",
                         what, status, plaintext, nonce, st, pt, n);
            end
            @(negedge clk);
            if (done !== 1'b0) begin errors = errors + 1; $display("FAIL: done dura mas de un ciclo"); end
        end
    endtask

    // Sustituye el caracter de la posicion pos (0 = primero)
    function [479:0] put_char(input [479:0] t, input integer pos, input [7:0] c);
        begin
            put_char = t;
            put_char[479 - 8*pos -: 8] = c;
        end
    endfunction

    function [7:0] get_char(input [479:0] t, input integer pos);
        get_char = t[479 - 8*pos -: 8];
    endfunction

    reg [127:0] v_key, v_pt, v_ct, v_tag;
    reg [95:0]  v_nonce;
    reg [479:0] v_text, alt;
    reg [8*256-1:0] vec_file;
    integer fd, n, vectors, pos;

    initial begin
        if (!$value$plusargs("VECTORS=%s", vec_file)) vec_file = "crypto_base64_vectors.txt";
        fd = $fopen(vec_file, "r");
        if (fd == 0) begin $display("FAIL: no se pudo abrir %0s", vec_file); $finish; end

        key = 0; text = 0;
        repeat (3) @(negedge clk);
        reset = 1'b0;
        repeat (2) @(negedge clk);

        vectors = 0;
        while (!$feof(fd)) begin
            n = $fscanf(fd, "%h %h %h %h %h %h\n", v_key, v_nonce, v_pt, v_ct, v_tag, v_text);
            if (n == 6) begin
                // 1. Valido
                run(v_key, v_text);
                if (cycles != 318) begin
                    errors = errors + 1; $display("FAIL: latencia %0d, esperada 318", cycles);
                end
                expect_result(2'd0, v_pt, v_nonce, "valido");

                // 2. Un caracter cambiado por otro valido -> etiqueta incorrecta
                pos = (vectors * 7) % 58;
                alt = put_char(v_text, pos, (get_char(v_text, pos) == "A") ? "B" : "A");
                run(v_key, alt);
                expect_result(2'd2, 128'd0, 96'd0, "alterado");

                // 3. Caracter fuera del alfabeto -> Base64 invalido
                alt = put_char(v_text, (vectors * 11) % 59, "*");
                run(v_key, alt);
                expect_result(2'd1, 128'd0, 96'd0, "base64");

                // 4. Clave equivocada -> etiqueta incorrecta
                run(v_key ^ 128'd1, v_text);
                expect_result(2'd2, 128'd0, 96'd0, "clave");

                vectors = vectors + 1;
            end
        end
        $fclose(fd);

        // Reset a mitad de un descifrado y uso inmediato
        key = v_key; text = v_text;
        @(negedge clk) start = 1'b1;
        @(negedge clk) start = 1'b0;
        repeat (150) @(negedge clk);
        reset = 1'b1; @(negedge clk); reset = 1'b0;
        if (busy || done || plaintext !== 128'd0) begin
            errors = errors + 1; $display("FAIL: reset no limpio");
        end
        run(v_key, v_text);
        expect_result(2'd0, v_pt, v_nonce, "tras reset");

        if (vectors != 19) begin errors = errors + 1; $display("FAIL: se leyeron %0d vectores", vectors); end

        if (errors == 0)
            $display("PASS: descifrado; %0d vectores OpenSSL, %0d comprobaciones (validos, alterados, Base64 invalido, clave equivocada), latencia 318, busy/done y reset.", vectors, checks);
        else
            $display("FALLO: %0d errores", errors);
        $finish;
    end

endmodule
