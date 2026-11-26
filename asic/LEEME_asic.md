# Layout del proyecto en SkyWater 130 nm (OpenLane)

Objetivo: pasar el mismo Verilog del proyecto a un **layout de chip (GDSII)** con el flujo abierto **OpenLane** y el PDK **sky130**. Es el flujo RTL → síntesis → floorplan → placement → CTS → routing → GDS.

## Archivos de esta carpeta

| Archivo | Para qué |
|---|---|
| `asic_top.v` | Top para chip. Es la misma lógica que `de10lite_top.v`, salvo tres cambios: el reloj entra directo a 25 MHz por `clk` (sin el divisor), el reset viene del pin `rst_n` y ningún registro tiene valor inicial, porque un chip no los tiene. |
| `config.json` | Configuración de OpenLane: top `asic_top`, reloj `clk` de 40 ns (25 MHz), 20 % de utilización y densidad 0.30. Con 35 % falló el ruteo global por congestión. |
| `src/` | Se crea en la VM: copia de los 16 `.v` de `quartus/`, todos menos `de10lite_top.v`. |

La simulación de `asic_top` reutiliza los bancos de prueba de la FPGA mediante `simulacion/asic_shim_de10lite.v`.

## Diferencias FPGA → ASIC (para explicarlas)

- **Reloj:** en la FPGA se dividía 50 MHz entre 2. En el chip se supone una entrada de 25 MHz, porque un reloj generado con un flip-flop complica el árbol de reloj (CTS).
- **Valores iniciales** (`reg x = 0`): la FPGA los carga al configurarse. Un chip arranca con valores al azar, así que todo depende del reset `rst_n`.
- **Recursos:** en la FPGA se cuentan LEs. En el chip se cuentan **celdas estándar** de `sky130_fd_sc_hd` (compuertas y flip-flops) y el **área en mm²**.

## Pasos en la máquina virtual (se ajustan cuando veamos qué trae la VM)

1. Copia la carpeta `asic/` a la VM y crea `asic/src/` con los 16 `.v` (todos los de `quartus/` menos `de10lite_top.v`).
2. **OpenLane 2:**
   `openlane config.json`
3. **OpenLane 1:**
   - Copia `asic/` a `OpenLane/designs/asic_top/`.
   - Dentro de OpenLane: `make mount`.
   - Luego: `./flow.tcl -design asic_top`.
4. Resultados en `runs/<fecha>/`:
   - `final/gds/asic_top.gds`: el layout. Se abre con `klayout` o `magic`.
   - Reportes de área, número de celdas, timing (slack) y DRC/LVS.

## Resultado obtenido (OpenLane 1, corrida RUN_2026.11.26_08.27.56)

| Dato | Valor |
|---|---|
| Celdas estándar | 119,710 |
| Tamaño del chip | 2.55 × 2.56 mm (6.51 mm²) |
| Timing a 25 MHz | Cumple: sin violaciones de setup ni de hold |
| DRC (Magic y KLayout) | 0 violaciones |
| LVS | Limpio: el layout coincide con el netlist |
| Antenas | 825 pines y 692 redes con aviso; se corregiría con diodos (no aplica para la entrega) |
| Tiempo de la corrida | 3 h, con 8 núcleos y 16 GB de RAM |

El layout está en `runs/RUN_2026.11.26_08.27.56/results/final/gds/asic_top.gds` (y en `mag/` para magic).

## Qué esperar

- El diseño es grande (en la FPGA usó ~38 mil LEs). La corrida puede tardar **varias horas** y necesita **8–16 GB de RAM** en la VM.
- Si se queda sin memoria o tarda demasiado, haz primero un bloque pequeño (por ejemplo `uart_tx` o `aes128_core`) para aprender el flujo y presentar ese layout.
