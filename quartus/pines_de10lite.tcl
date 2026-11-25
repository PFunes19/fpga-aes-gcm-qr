# Asignacion de pines para de10lite_top (DE10-Lite, 10M50DAF484C7G)
# Uso en Quartus (con el proyecto abierto):
#   Tools > Tcl Scripts... > elegir este archivo > Run
#   o en la consola Tcl:  source pines_de10lite.tcl
# Despues: Processing > Start Compilation.
# Verificar contra el manual de la DE10-Lite (tablas de pines) antes de programar.

proc pin {nombre ubicacion} {
    set_location_assignment $ubicacion -to $nombre
    set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to $nombre
}

# Reloj
pin MAX10_CLK1_50 PIN_P11

# Botones
pin KEY[0] PIN_B8
pin KEY[1] PIN_A7

# Interruptores
pin SW[0] PIN_C10
pin SW[1] PIN_C11
pin SW[2] PIN_D12
pin SW[3] PIN_C12
pin SW[4] PIN_A12
pin SW[5] PIN_B12
pin SW[6] PIN_A13
pin SW[7] PIN_A14
pin SW[8] PIN_B14
pin SW[9] PIN_F15

# LEDs
pin LEDR[0] PIN_A8
pin LEDR[1] PIN_A9
pin LEDR[2] PIN_A10
pin LEDR[3] PIN_B10
pin LEDR[4] PIN_D13
pin LEDR[5] PIN_C13
pin LEDR[6] PIN_E14
pin LEDR[7] PIN_D14
pin LEDR[8] PIN_A11
pin LEDR[9] PIN_B11

# Displays de 7 segmentos: [0..6] = a..g, [7] = punto
set hex0 {C14 E15 C15 C16 E16 D17 C17 D15}
set hex1 {C18 D18 E18 B16 A17 A18 B17 A16}
set hex2 {B20 A20 B19 A21 B21 C22 B22 A19}
set hex3 {F21 E22 E21 C19 C20 D19 E17 D22}
set hex4 {F18 E20 E19 J18 H19 F19 F20 F17}
set hex5 {J20 K20 L18 N18 M20 N19 N20 L19}
foreach d {0 1 2 3 4 5} {
    set lista [set hex$d]
    for {set i 0} {$i < 8} {incr i} {
        pin "HEX${d}\[$i\]" "PIN_[lindex $lista $i]"
    }
}

# VGA
pin VGA_R[0] PIN_AA1
pin VGA_R[1] PIN_V1
pin VGA_R[2] PIN_Y2
pin VGA_R[3] PIN_Y1
pin VGA_G[0] PIN_W1
pin VGA_G[1] PIN_T2
pin VGA_G[2] PIN_R2
pin VGA_G[3] PIN_R1
pin VGA_B[0] PIN_P1
pin VGA_B[1] PIN_T1
pin VGA_B[2] PIN_P4
pin VGA_B[3] PIN_N2
pin VGA_HS PIN_N3
pin VGA_VS PIN_N1

# UART con la ESP32 (header Arduino: D0 = AB5, D1 = AB6)
pin UART_RX PIN_AB5
pin UART_TX PIN_AB6
set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to UART_RX

export_assignments
puts "Listo: 87 pines asignados (3.3-V LVTTL)."
