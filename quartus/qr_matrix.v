`timescale 1ns/1ps

// QR Model 2, version 4, correccion M: matriz de 33 x 33.
// Entrada: los 100 bytes YA intercalados de qr_rs_encoder, MSB primero.
// Salida: matrix_out[1088 - (fila*33 + columna)], 1=negro, 0=blanco.
// (0,0) es la esquina superior izquierda. No incluye margen blanco:
// al visualizar, agregar al menos cuatro modulos por cada lado.
//
// Coloca 800 bits y 7 bits restantes cero; aplica mascara SOLO a estos.
// Incluye patrones, separadores, temporizacion, alineacion en (26,26),
// modulo oscuro e informacion de formato M con BCH y XOR 0x5412.
// Evalua las 8 mascaras con N1, N2, N3 y N4; en empate gana la menor.
// N3 considera proporciones 1:1:3:1:1 y el borde claro exterior.
//
// start se acepta con busy=0. Captura la entrada y borra las salidas.
// done pulsa 28257 ciclos despues; publica matriz y mascara completas.
// Ignora start durante busy. Reset asincrono activo en alto.
// No verifica el contenido ni la paridad de los codewords recibidos.
//
// El calculo N3 por historial se adapto de Project Nayuki (MIT).
// Ver LICENSE_qr_reference.txt y la referencia en LEEME_qr_matrix.txt.

module qr_matrix (
    input  wire          clk,
    input  wire          reset,
    input  wire          start,
    input  wire [799:0]  codewords_in,
    output reg  [1088:0] matrix_out,
    output reg  [2:0]    mask_out,
    output reg           busy,
    output reg           done
);

    localparam [2:0] IDLE      = 3'd0,
                     PLACE     = 3'd1,
                     APPLY     = 3'd2,
                     SCORE     = 3'd3,
                     END_DARK  = 3'd4,
                     END_LIGHT = 3'd5,
                     CHOOSE    = 3'd6,
                     FINISH    = 3'd7;

    reg [2:0] state;
    reg [799:0] data_shift;
    reg [1088:0] raw_matrix, candidate, best_matrix;
    reg [2:0] current_mask, best_mask;
    reg [15:0] score, best_score;
    reg [10:0] dark_count;

    reg [5:0] map_row, right_col;
    reg left_side, upward;
    reg [5:0] draw_row, draw_col;
    reg [5:0] line_number, position;
    reg vertical, run_color;
    reg [5:0] run_length;
    // Siete longitudes; la mas reciente ocupa [55:48].
    reg [55:0] history;

    function [10:0] pixel_index;
        input [5:0] row, col;
        begin
            pixel_index = 11'd1088 - (row * 11'd33 + col);
        end
    endfunction

    // Formato BCH(15,5), nivel M (bits de nivel = 00), para cada mascara.
    function [14:0] format_bits;
        input [2:0] mask;
        begin
            case (mask)
                3'd0: format_bits = 15'h5412;
                3'd1: format_bits = 15'h5125;
                3'd2: format_bits = 15'h5E7C;
                3'd3: format_bits = 15'h5B4B;
                3'd4: format_bits = 15'h45F9;
                3'd5: format_bits = 15'h40CE;
                3'd6: format_bits = 15'h4F97;
                3'd7: format_bits = 15'h4AA0;
            endcase
        end
    endfunction

    // Devuelve {reservado, color}. Coordenadas fijas para version 4.
    function [1:0] function_cell;
        input [5:0] row, col;
        input [2:0] mask;
        reg [14:0] fmt;
        integer center_row, center_col, dy, dx, distance;
        begin
            function_cell = 2'b00;
            fmt = format_bits(mask);
            center_row = 3;
            center_col = 3;
            dy = 0;
            dx = 0;
            distance = 0;
            if ((row <= 7 && col <= 7) ||
                (row <= 7 && col >= 25) ||
                (row >= 25 && col <= 7)) begin
                if (row >= 25) center_row = 29;
                if (col >= 25) center_col = 29;
                dy = (row >= center_row) ? row - center_row : center_row - row;
                dx = (col >= center_col) ? col - center_col : center_col - col;
                distance = (dy > dx) ? dy : dx;
                function_cell = {1'b1, (distance != 2 && distance != 4)};
            end else if (row == 6 || col == 6) begin
                function_cell = {1'b1, (row == 6 ? !col[0] : !row[0])};
            end else if (row >= 24 && row <= 28 && col >= 24 && col <= 28) begin
                function_cell = {1'b1, (row == 24 || row == 28 ||
                                       col == 24 || col == 28 ||
                                       (row == 26 && col == 26))};
            end else if (row == 25 && col == 8) begin
                function_cell = 2'b11;
            end else if (col == 8 && row <= 5) begin
                function_cell = {1'b1, fmt[row]};
            end else if (col == 8 && row == 7) begin
                function_cell = {1'b1, fmt[6]};
            end else if (col == 8 && row == 8) begin
                function_cell = {1'b1, fmt[7]};
            end else if (row == 8 && col == 7) begin
                function_cell = {1'b1, fmt[8]};
            end else if (row == 8 && col <= 5) begin
                function_cell = {1'b1, fmt[14-col]};
            end else if (row == 8 && col >= 25) begin
                function_cell = {1'b1, fmt[32-col]};
            end else if (col == 8 && row >= 26) begin
                function_cell = {1'b1, fmt[row-18]};
            end
        end
    endfunction

    function mask_bit;
        input [5:0] row, col;
        input [2:0] mask;
        reg [6:0] sum;
        reg [11:0] product;
        begin
            sum = {1'b0, row} + {1'b0, col};
            product = row * col;
            case (mask)
                3'd0: mask_bit = (sum % 2 == 0);
                3'd1: mask_bit = (row % 2 == 0);
                3'd2: mask_bit = (col % 3 == 0);
                3'd3: mask_bit = (sum % 3 == 0);
                3'd4: mask_bit = ((row / 2 + col / 3) % 2 == 0);
                3'd5: mask_bit = (product % 2 + product % 3 == 0);
                3'd6: mask_bit = ((product % 2 + product % 3) % 2 == 0);
                3'd7: mask_bit = ((sum % 2 + product % 3) % 2 == 0);
            endcase
        end
    endfunction

    function [55:0] push_run;
        input [55:0] previous;
        input [7:0] length;
        reg [7:0] extended_length;
        begin
            // Simula el espacio claro fuera del comienzo de la linea.
            extended_length = length + (previous[55:48] == 0 ? 8'd33 : 8'd0);
            push_run = {extended_length, previous[55:8]};
        end
    endfunction

    function [6:0] finder_penalty;
        input [55:0] runs;
        reg [7:0] n;
        reg [9:0] three_n, four_n;
        reg core;
        begin
            n = runs[47:40];
            three_n = {2'b0, n} * 10'd3;
            four_n = {2'b0, n} * 10'd4;
            core = n != 0 && runs[39:32] == n && runs[23:16] == n &&
                   runs[15:8] == n && runs[31:24] == three_n;
            finder_penalty = 7'd0;
            if (core && runs[55:48] >= four_n && runs[7:0] >= n)
                finder_penalty = finder_penalty + 7'd40;
            if (core && runs[7:0] >= four_n && runs[55:48] >= n)
                finder_penalty = finder_penalty + 7'd40;
        end
    endfunction

    function [6:0] balance_penalty;
        input [10:0] dark;
        reg [14:0] scaled, deviation;
        integer threshold;
        begin
            scaled = dark * 15'd20;
            deviation = (scaled > 15'd10890) ? scaled - 15'd10890 : 15'd10890 - scaled;
            balance_penalty = 7'd0;
            // Equivale a (ceil(abs(20*dark - 10*1089)/1089)-1)*10.
            // Nueve comparaciones constantes evitan un divisor variable.
            for (threshold = 1; threshold <= 9; threshold = threshold + 1)
                if (deviation > 1089 * threshold)
                    balance_penalty = balance_penalty + 7'd10;
        end
    endfunction

    wire [5:0] map_col = right_col - left_side;
    wire [1:0] map_function = function_cell(map_row, map_col, 3'd0);
    wire [1:0] draw_function = function_cell(draw_row, draw_col, current_mask);
    wire [5:0] score_row = vertical ? position : line_number;
    wire [5:0] score_col = vertical ? line_number : position;
    wire [10:0] score_index = pixel_index(score_row, score_col);
    wire cell_color = candidate[score_index];
    wire [55:0] changed_history = push_run(history, {2'b00, run_length});
    wire [55:0] final_history = push_run(history, {2'b00, run_length} + 8'd33);
    wire [15:0] total_score = score + balance_penalty(dark_count);
    reg [7:0] pixel_penalty;

    always @* begin
        pixel_penalty = 8'd0;
        // N1: tres puntos al llegar a cinco, uno por cada modulo adicional.
        if (cell_color == run_color) begin
            if (run_length == 4) pixel_penalty = 8'd3;
            else if (run_length >= 5) pixel_penalty = 8'd1;
        end else if (!run_color) begin
            pixel_penalty = finder_penalty(changed_history);
        end
        // N2: cada cuadrado se cuenta solo al recorrer filas.
        if (!vertical && score_row != 0 && score_col != 0) begin
            if (cell_color == candidate[score_index + 11'd1] &&
                cell_color == candidate[score_index + 11'd33] &&
                cell_color == candidate[score_index + 11'd34])
                pixel_penalty = pixel_penalty + 8'd3;
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            data_shift <= 800'd0;
            raw_matrix <= 1089'd0;
            candidate <= 1089'd0;
            best_matrix <= 1089'd0;
            matrix_out <= 1089'd0;
            mask_out <= 3'd0;
            current_mask <= 3'd0;
            best_mask <= 3'd0;
            score <= 16'd0;
            best_score <= 16'hFFFF;
            dark_count <= 11'd0;
            map_row <= 6'd32;
            right_col <= 6'd32;
            left_side <= 1'b0;
            upward <= 1'b1;
            draw_row <= 6'd0;
            draw_col <= 6'd0;
            line_number <= 6'd0;
            position <= 6'd0;
            vertical <= 1'b0;
            run_color <= 1'b0;
            run_length <= 6'd0;
            history <= 56'd0;
            busy <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: if (start) begin
                    data_shift <= codewords_in;
                    raw_matrix <= 1089'd0;
                    matrix_out <= 1089'd0;
                    mask_out <= 3'd0;
                    best_matrix <= 1089'd0;
                    best_score <= 16'hFFFF;
                    best_mask <= 3'd0;
                    current_mask <= 3'd0;
                    map_row <= 6'd32;
                    right_col <= 6'd32;
                    left_side <= 1'b0;
                    upward <= 1'b1;
                    busy <= 1'b1;
                    state <= PLACE;
                end

                PLACE: begin
                    if (!map_function[1]) begin
                        raw_matrix[pixel_index(map_row, map_col)] <= data_shift[799];
                        // Tras 800 desplazamientos quedan los siete ceros.
                        data_shift <= {data_shift[798:0], 1'b0};
                    end
                    if (!left_side) begin
                        left_side <= 1'b1;
                    end else begin
                        left_side <= 1'b0;
                        if ((upward && map_row == 0) || (!upward && map_row == 32)) begin
                            if (right_col == 1) begin
                                draw_row <= 6'd0;
                                draw_col <= 6'd0;
                                state <= APPLY;
                            end else begin
                                // Saltar la columna 6 de temporizacion.
                                right_col <= (right_col == 8) ? 6'd5 : right_col - 6'd2;
                                upward <= !upward;
                            end
                        end else begin
                            map_row <= upward ? map_row - 6'd1 : map_row + 6'd1;
                        end
                    end
                end

                APPLY: begin
                    if (draw_function[1])
                        candidate[pixel_index(draw_row, draw_col)] <= draw_function[0];
                    else
                        candidate[pixel_index(draw_row, draw_col)] <=
                            raw_matrix[pixel_index(draw_row, draw_col)] ^ mask_bit(draw_row, draw_col, current_mask);
                    if (draw_col == 32) begin
                        draw_col <= 6'd0;
                        if (draw_row == 32) begin
                            score <= 16'd0;
                            dark_count <= 11'd0;
                            line_number <= 6'd0;
                            position <= 6'd0;
                            vertical <= 1'b0;
                            run_color <= 1'b0;
                            run_length <= 6'd0;
                            history <= 56'd0;
                            state <= SCORE;
                        end else draw_row <= draw_row + 6'd1;
                    end else draw_col <= draw_col + 6'd1;
                end

                SCORE: begin
                    score <= score + pixel_penalty;
                    if (!vertical && cell_color) dark_count <= dark_count + 11'd1;
                    if (cell_color == run_color) begin
                        run_length <= run_length + 6'd1;
                    end else begin
                        history <= changed_history;
                        run_color <= cell_color;
                        run_length <= 6'd1;
                    end
                    if (position == 32) state <= END_DARK;
                    else position <= position + 6'd1;
                end

                END_DARK: begin
                    if (run_color) begin
                        history <= changed_history;
                        run_length <= 6'd0;
                    end
                    state <= END_LIGHT;
                end

                END_LIGHT: begin
                    // N3: cerrar la linea agregando el borde claro exterior.
                    score <= score + finder_penalty(final_history);
                    position <= 6'd0;
                    run_color <= 1'b0;
                    run_length <= 6'd0;
                    history <= 56'd0;
                    if (line_number == 32) begin
                        line_number <= 6'd0;
                        if (vertical) state <= CHOOSE;
                        else begin
                            vertical <= 1'b1;
                            state <= SCORE;
                        end
                    end else begin
                        line_number <= line_number + 6'd1;
                        state <= SCORE;
                    end
                end

                CHOOSE: begin
                    if (total_score < best_score) begin
                        best_score <= total_score;
                        best_mask <= current_mask;
                        best_matrix <= candidate;
                    end
                    if (current_mask == 7) state <= FINISH;
                    else begin
                        current_mask <= current_mask + 3'd1;
                        draw_row <= 6'd0;
                        draw_col <= 6'd0;
                        state <= APPLY;
                    end
                end

                FINISH: begin
                    matrix_out <= best_matrix;
                    mask_out <= best_mask;
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end
endmodule
