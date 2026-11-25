module uart_rx #(
    parameter CLK_FREQ  = 50000000,
    parameter BAUD_RATE = 9600
)(
    input  wire clk,
    input  wire reset,
    input  wire rx,
    output reg [7:0] data_out,
    output reg data_valid,
    output reg frame_error
);

localparam integer CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
localparam integer FIRST_SAMPLE = CLKS_PER_BIT + CLKS_PER_BIT/2;

reg [15:0] clk_count;
reg [3:0]  bit_index;
reg [7:0]  rx_shift;
reg        receiving;

// Sincroniza la entrada externa con el reloj.
reg rx_meta;
reg rx_sync;
reg wait_high;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        clk_count  <= 0;
        bit_index  <= 0;
        rx_shift   <= 0;
        receiving  <= 1'b0;
        data_out   <= 8'd0;
        data_valid <= 1'b0;
        frame_error <= 1'b0;
        rx_meta    <= 1'b1;
        rx_sync    <= 1'b1;
        wait_high  <= 1'b0;
    end else begin
        rx_meta <= rx;
        rx_sync <= rx_meta;

        data_valid  <= 1'b0;
        frame_error <= 1'b0;

        if (!receiving) begin
            // Tras una parada incorrecta, espera a que la linea vuelva a alto.
            if (wait_high) begin
                if (rx_sync == 1'b1)
                    wait_high <= 1'b0;
            end else if (rx_sync == 1'b0) begin
                receiving <= 1'b1;
                clk_count <= 0;
                bit_index <= 0;
            end
        end else begin
            // Primer dato: 1.5 bits desde el inicio. Los demas: un bit.
            if (clk_count < ((bit_index == 0) ? FIRST_SAMPLE - 1 : CLKS_PER_BIT - 1)) begin
                clk_count <= clk_count + 1;
            end else begin
                clk_count <= 0;

                if (bit_index < 8) begin
                    rx_shift[bit_index] <= rx_sync;
                    bit_index <= bit_index + 1;
                end else begin
                    receiving <= 1'b0;
                    // Solo entrega el byte si el bit de parada es valido.
                    if (rx_sync == 1'b1) begin
                        data_out   <= rx_shift;
                        data_valid <= 1'b1;
                    end else begin
                        frame_error <= 1'b1;
                        wait_high   <= 1'b1;
                    end
                end
            end
        end
    end
end

endmodule
