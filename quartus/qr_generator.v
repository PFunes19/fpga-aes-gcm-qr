`timescale 1ns/1ps

// Generador QR completo para nuestro perfil fijo: version 4, nivel M,
// modo byte y exactamente 60 bytes (normalmente el texto de base64_encode).
// Instancia qr_data_encode -> qr_rs_encoder -> qr_matrix sin modificarlos.
// No valida Base64: transporta los 60 bytes recibidos, sin NUL ni salto final.
//
// text_in[479:472] es el primer byte. La primera etapa captura text_in
// en el mismo flanco en que este controlador acepta start.
// matrix_out[1088 - (fila*33 + columna)]: 1=negro, 0=blanco, filas/columnas 0..32.
// La matriz no incluye el margen blanco de cuatro modulos para visualizarla.
//
// start: pulso de un ciclo con busy=0. Ignora solicitudes durante busy.
// busy permanece activo entre etapas; done pulsa al publicar el resultado.
// Las salidas se borran al iniciar y se conservan despues de terminar.
// Latencia: 29480 ciclos desde la aceptacion de start hasta done.
// Reset asincrono activo en alto, compartido por los tres submodulos.

module qr_generator (
    input  wire          clk,
    input  wire          reset,
    input  wire          start,
    input  wire [479:0]  text_in,
    output reg  [1088:0] matrix_out,
    output reg  [2:0]    mask_out,
    output reg           busy,
    output reg           done
);

    localparam [1:0] IDLE        = 2'd0,
                     WAIT_DATA   = 2'd1,
                     WAIT_RS     = 2'd2,
                     WAIT_MATRIX = 2'd3;
    reg [1:0] state;

    wire [511:0] prepared_data;
    wire [799:0] codewords;
    wire [1088:0] completed_matrix;
    wire [2:0] completed_mask;
    wire data_done, rs_done, matrix_done;

    // Cada pulso dura un ciclo. La FSM solo habilita la etapa que sigue.
    // Un done registrado garantiza que su salida ya este disponible.
    wire data_start   = (state == IDLE) && start;
    wire rs_start     = (state == WAIT_DATA) && data_done;
    wire matrix_start = (state == WAIT_RS) && rs_done;

    qr_data_encode data_encoder (
        .clk(clk), .reset(reset), .start(data_start), .text_in(text_in),
        .data_out(prepared_data), .busy(), .done(data_done)
    );

    qr_rs_encoder rs_encoder (
        .clk(clk), .reset(reset), .start(rs_start), .data_in(prepared_data),
        .codewords_out(codewords), .busy(), .done(rs_done)
    );

    qr_matrix matrix_builder (
        .clk(clk), .reset(reset), .start(matrix_start), .codewords_in(codewords),
        .matrix_out(completed_matrix), .mask_out(completed_mask),
        .busy(), .done(matrix_done)
    );

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            matrix_out <= 1089'd0;
            mask_out <= 3'd0;
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: begin
                    if (start) begin
                        matrix_out <= 1089'd0;
                        mask_out <= 3'd0;
                        busy <= 1'b1;
                        state <= WAIT_DATA;
                    end
                end

                WAIT_DATA: begin
                    if (data_done)
                        state <= WAIT_RS;
                end

                WAIT_RS: begin
                    if (rs_done)
                        state <= WAIT_MATRIX;
                end

                WAIT_MATRIX: begin
                    if (matrix_done) begin
                        matrix_out <= completed_matrix;
                        mask_out <= completed_mask;
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end
endmodule
