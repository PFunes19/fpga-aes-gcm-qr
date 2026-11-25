`timescale 1ns/1ps

// Top para la DE10-Lite: AES-128-GCM + Base64 + QR por VGA, con comandos
// por UART desde una ESP32.
//
// Flujo previsto:
//   PC --Wi-Fi--> ESP32 --UART 'E'--> FPGA: cifra, muestra el QR y contesta 'C'
//   iPhone lee el QR --Wi-Fi--> ESP32 --UART 'D'--> FPGA: descifra, contesta 'P'
//   ESP32 --Wi-Fi--> PC muestra el resultado
//
// PROTOCOLO UART (8N1, UART_BAUD, por defecto 115200). Ver uart_command_port.
//   Solicitudes ESP32 -> FPGA:
//     'E' + 16 bytes    cifrar esos 16 bytes y mostrar su QR
//     'D' + 60 bytes    descifrar ese texto Base64
//   Respuestas FPGA -> ESP32:
//     'C' + 60 bytes    texto Base64 del QR que se acaba de mostrar
//                       (tambien se envia al cifrar con KEY1)
//     'P' + estado + 16 bytes   resultado del descifrado:
//          estado 'K' = etiqueta correcta, siguen los 16 bytes originales
//                 'T' = etiqueta incorrecta (alterado o clave distinta), 16 ceros
//                 'B' = Base64 invalido, 16 ceros
//   Una solicitud a la vez: esperar la respuesta antes de enviar otra.
//
// Botones e interruptores (siguen funcionando sin ESP32):
//   KEY0 reset.  KEY1 cifra "DE10-Lite SW=xyz" (xyz = SW en hex).
//   LEDR0 busy, LEDR1 QR valido en pantalla,
//   LEDR2 ultimo descifrado correcto, LEDR3 etiqueta incorrecta,
//   LEDR4 Base64 invalido. HEX3..HEX0 numero de mensaje, HEX5 mascara.
//
// Clave AES-128 FIJA DE PRUEBA y nonce = {NONCE_PREFIX, contador}: el
// contador vuelve a 0 con reset o al apagar, asi que los nonces se repiten
// entre encendidos. Solo para demostracion.

module de10lite_top #(
    parameter [127:0] DEMO_KEY        = 128'h000102030405060708090a0b0c0d0e0f,
    parameter [63:0]  NONCE_PREFIX    = 64'hde10_11fe_0000_0000,
    parameter integer DEBOUNCE_CYCLES = 250000,    // 10 ms a 25 MHz
    parameter integer POR_BITS        = 20,        // ~42 ms de reset al encender
    parameter integer UART_BAUD       = 115200,
    parameter integer UART_TIMEOUT    = 1250000    // 50 ms sin bytes en una trama
)(
    input  wire        MAX10_CLK1_50,
    input  wire [1:0]  KEY,          // activos en bajo
    input  wire [9:0]  SW,

    output wire [9:0]  LEDR,
    output wire [7:0]  HEX0,
    output wire [7:0]  HEX1,
    output wire [7:0]  HEX2,
    output wire [7:0]  HEX3,
    output wire [7:0]  HEX4,
    output wire [7:0]  HEX5,

    output wire [3:0]  VGA_R,
    output wire [3:0]  VGA_G,
    output wire [3:0]  VGA_B,
    output wire        VGA_HS,
    output wire        VGA_VS,

    input  wire        UART_RX,      // desde TX de la ESP32 (GPIO17 / TX2)
    output wire        UART_TX       // hacia RX de la ESP32 (GPIO16 / RX2)
);

    // ------------------------------------------------------------------
    // Reloj del sistema: 25 MHz (50 MHz / 2). El camino mas lento del
    // diseno (~29 ns en Quartus) no cumple 20 ns, pero si 40 ns. El VGA ya
    // trabajaba a 25 MHz, asi que la pantalla no cambia.
    // de10lite_top.sdc declara este reloj (create_generated_clock).
    // ------------------------------------------------------------------
    localparam integer CLK_HZ = 25000000;
    reg clk_div = 1'b0;
    always @(posedge MAX10_CLK1_50)
        clk_div <= ~clk_div;
    wire clk = clk_div;

    // ------------------------------------------------------------------
    // Reset: al encender (contador) o con KEY0. Asercion asincrona,
    // liberacion sincronizada.
    // ------------------------------------------------------------------
    reg [POR_BITS-1:0] por_cnt = {POR_BITS{1'b0}};
    wire por_done = &por_cnt;
    always @(posedge clk)
        if (!por_done) por_cnt <= por_cnt + 1'b1;

    wire reset_req = ~por_done | ~KEY[0];

    reg [1:0] rst_sync = 2'b11;
    always @(posedge clk or posedge reset_req)
        if (reset_req) rst_sync <= 2'b11;
        else           rst_sync <= {rst_sync[0], 1'b0};
    wire reset = rst_sync[1];

    // ------------------------------------------------------------------
    // KEY1: sincronizacion, antirrebote y pulso de un ciclo al pulsar.
    // ------------------------------------------------------------------
    reg [1:0]  key1_sync;
    reg        key1_stable;
    reg [18:0] deb_cnt;
    reg        key1_prev;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            key1_sync   <= 2'b00;
            key1_stable <= 1'b0;
            deb_cnt     <= 19'd0;
            key1_prev   <= 1'b0;
        end else begin
            key1_sync <= {key1_sync[0], ~KEY[1]};
            if (key1_sync[1] == key1_stable)
                deb_cnt <= 19'd0;
            else if (deb_cnt == DEBOUNCE_CYCLES-1) begin
                deb_cnt     <= 19'd0;
                key1_stable <= key1_sync[1];
            end else
                deb_cnt <= deb_cnt + 19'd1;
            key1_prev <= key1_stable;
        end
    end
    wire key_pulse = key1_stable & ~key1_prev;

    // ------------------------------------------------------------------
    // Mensaje de los interruptores: "DE10-Lite SW=" + 3 digitos hex.
    // ------------------------------------------------------------------
    reg [9:0] sw_s1, sw_s2;
    always @(posedge clk) begin
        sw_s1 <= SW;
        sw_s2 <= sw_s1;
    end

    function [7:0] hex_ascii;
        input [3:0] d;
        hex_ascii = (d < 4'd10) ? (8'h30 + {4'd0, d}) : (8'h41 + {4'd0, d} - 8'd10);
    endfunction

    wire [127:0] sw_message = {"DE10-Lite SW=",
                               hex_ascii({2'b00, sw_s2[9:8]}),
                               hex_ascii(sw_s2[7:4]),
                               hex_ascii(sw_s2[3:0])};

    // ------------------------------------------------------------------
    // Puerto UART de comandos
    // ------------------------------------------------------------------
    reg uart_rx_s1, uart_rx_s2;     // uart_rx ya sincroniza; esto solo da
    always @(posedge clk) begin     // un registro cerca del pin de entrada
        uart_rx_s1 <= UART_RX;
        uart_rx_s2 <= uart_rx_s1;
    end

    wire         cmd_valid;
    wire [7:0]   cmd_type;
    wire [479:0] cmd_payload;
    reg          cmd_ack;
    reg          resp_start;
    reg  [6:0]   resp_len;
    reg  [487:0] resp_data;
    wire         resp_busy;

    uart_command_port #(
        .CLK_FREQ(CLK_HZ), .BAUD_RATE(UART_BAUD), .TIMEOUT_CYCLES(UART_TIMEOUT)
    ) puerto (
        .clk(clk), .reset(reset), .rx(uart_rx_s2), .tx(UART_TX),
        .cmd_valid(cmd_valid), .cmd_type(cmd_type), .cmd_payload(cmd_payload),
        .cmd_ack(cmd_ack),
        .resp_start(resp_start), .resp_len(resp_len), .resp_data(resp_data),
        .resp_busy(resp_busy)
    );

    // ------------------------------------------------------------------
    // Maquina de comandos: una operacion a la vez, luego su respuesta.
    // ------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_ENC = 2'd1, S_DEC = 2'd2, S_RESP = 2'd3;
    reg [1:0] state;

    wire uart_enc = (state == S_IDLE) && cmd_valid && (cmd_type == "E");
    wire uart_dec = (state == S_IDLE) && cmd_valid && (cmd_type == "D");
    wire key_enc  = (state == S_IDLE) && !cmd_valid && key_pulse;
    wire enc_start = uart_enc || key_enc;

    // Cifrado + Base64 + QR
    reg  [31:0]   msg_count;
    wire [95:0]   nonce = {NONCE_PREFIX, msg_count};
    wire [127:0]  enc_plain = uart_enc ? cmd_payload[127:0] : sw_message;
    wire [351:0]  packet;
    wire [479:0]  text;
    wire [1088:0] matrix;
    wire [2:0]    mask;
    wire          enc_busy, enc_done;

    crypto_qr_controller controlador (
        .clk(clk), .reset(reset), .start(enc_start),
        .key(DEMO_KEY), .nonce(nonce), .plaintext(enc_plain),
        .packet_out(packet), .text_out(text), .matrix_out(matrix),
        .mask_out(mask), .busy(enc_busy), .done(enc_done)
    );

    // Descifrado
    wire [127:0] dec_plain;
    wire [1:0]   dec_status;
    wire         dec_done;

    crypto_decrypt_controller descifrador (
        .clk(clk), .reset(reset), .start(uart_dec),
        .key(DEMO_KEY), .text_in(cmd_payload),
        .plaintext_out(dec_plain), .nonce_out(), .status_out(dec_status),
        .busy(), .done(dec_done)
    );

    function [7:0] status_char;
        input [1:0] s;
        case (s)
            2'd0:    status_char = "K";
            2'd1:    status_char = "B";
            default: status_char = "T";
        endcase
    endfunction

    reg       qr_valid;
    reg [15:0] shown_count;
    reg [2:0]  shown_mask;
    reg [2:0]  dec_leds;      // {base64 invalido, etiqueta incorrecta, correcto}

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state       <= S_IDLE;
            msg_count   <= 32'd0;
            cmd_ack     <= 1'b0;
            resp_start  <= 1'b0;
            resp_len    <= 7'd0;
            resp_data   <= 488'd0;
            qr_valid    <= 1'b0;
            shown_count <= 16'd0;
            shown_mask  <= 3'd0;
            dec_leds    <= 3'b000;
        end else begin
            cmd_ack    <= 1'b0;
            resp_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (enc_start) begin
                        // El controlador captura entradas en este flanco.
                        msg_count <= msg_count + 32'd1;
                        qr_valid  <= 1'b0;
                        cmd_ack   <= uart_enc;
                        state     <= S_ENC;
                    end else if (uart_dec) begin
                        cmd_ack   <= 1'b1;
                        state     <= S_DEC;
                    end
                end

                S_ENC: begin
                    if (enc_done) begin
                        qr_valid    <= 1'b1;
                        shown_count <= packet[271:256];
                        shown_mask  <= mask;
                        resp_data   <= {"C", text};
                        resp_len    <= 7'd61;
                        resp_start  <= 1'b1;
                        state       <= S_RESP;
                    end
                end

                S_DEC: begin
                    if (dec_done) begin
                        dec_leds   <= (dec_status == 2'd0) ? 3'b001 :
                                      (dec_status == 2'd1) ? 3'b100 : 3'b010;
                        resp_data  <= {"P", status_char(dec_status), dec_plain, 344'd0};
                        resp_len   <= 7'd18;
                        resp_start <= 1'b1;
                        state      <= S_RESP;
                    end
                end

                S_RESP: begin
                    // resp_busy sube en el flanco que sigue a resp_start
                    if (!resp_start && !resp_busy)
                        state <= S_IDLE;
                end
            endcase
        end
    end

    // cmd_ack se registra: evitar que la misma trama se vea dos veces
    // (en S_IDLE solo se actua en el flanco de entrada; despues el estado
    // ya no es S_IDLE hasta terminar la respuesta).

    // ------------------------------------------------------------------
    // Pantalla VGA
    // ------------------------------------------------------------------
    vga_qr_display #(.PIX_DIV(1)) pantalla (
        .clk(clk), .reset(reset),
        .matrix_in(matrix), .valid(qr_valid),
        .vga_r(VGA_R), .vga_g(VGA_G), .vga_b(VGA_B),
        .vga_hs(VGA_HS), .vga_vs(VGA_VS)
    );

    // ------------------------------------------------------------------
    // LEDs y displays (segmentos activos en bajo; bit 7 = punto)
    // ------------------------------------------------------------------
    wire busy_any = (state != S_IDLE);
    assign LEDR = {5'd0, dec_leds[2], dec_leds[1], dec_leds[0], qr_valid, busy_any};

    function [7:0] seg7;
        input [3:0] d;
        case (d)
            4'h0: seg7 = 8'b11000000;
            4'h1: seg7 = 8'b11111001;
            4'h2: seg7 = 8'b10100100;
            4'h3: seg7 = 8'b10110000;
            4'h4: seg7 = 8'b10011001;
            4'h5: seg7 = 8'b10010010;
            4'h6: seg7 = 8'b10000010;
            4'h7: seg7 = 8'b11111000;
            4'h8: seg7 = 8'b10000000;
            4'h9: seg7 = 8'b10010000;
            4'hA: seg7 = 8'b10001000;
            4'hB: seg7 = 8'b10000011;
            4'hC: seg7 = 8'b11000110;
            4'hD: seg7 = 8'b10100001;
            4'hE: seg7 = 8'b10000110;
            default: seg7 = 8'b10001110;   // F
        endcase
    endfunction

    assign HEX0 = qr_valid ? seg7(shown_count[3:0])   : 8'hBF;  // '-' sin QR
    assign HEX1 = qr_valid ? seg7(shown_count[7:4])   : 8'hBF;
    assign HEX2 = qr_valid ? seg7(shown_count[11:8])  : 8'hBF;
    assign HEX3 = qr_valid ? seg7(shown_count[15:12]) : 8'hBF;
    assign HEX4 = 8'hFF;
    assign HEX5 = qr_valid ? seg7({1'b0, shown_mask}) : 8'hBF;

endmodule
