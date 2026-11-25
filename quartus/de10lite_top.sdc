# Restricciones de tiempo para de10lite_top (DE10-Lite, MAX 10)

# Reloj de 50 MHz de la placa
create_clock -name MAX10_CLK1_50 -period 20.000 [get_ports {MAX10_CLK1_50}]

# Reloj del sistema: 25 MHz, generado por el registro clk_div (50 MHz / 2).
# Toda la logica del diseno usa este reloj.
create_generated_clock -name CLK25 -source [get_ports {MAX10_CLK1_50}] \
    -divide_by 2 [get_registers {clk_div}]

derive_clock_uncertainty

# Entradas asincronas (botones, interruptores, UART): se sincronizan en el RTL.
set_false_path -from [get_ports {KEY[*] SW[*] UART_RX}]
set_false_path -to   [get_ports {UART_TX}]

# Salidas lentas, sin relacion de tiempo con un dispositivo externo.
set_false_path -to [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]}]

# VGA: salidas registradas que cambian a 25 MHz; el monitor no se sincroniza
# con un reloj de la FPGA, asi que no hay requisito de E/S.
set_false_path -to [get_ports {VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS}]
