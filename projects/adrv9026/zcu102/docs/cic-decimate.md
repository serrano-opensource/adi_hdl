# ADRV9026 ZCU102 — RX CIC Decimation

## Original requirements

The following is the design prompt this feature was implemented against
(originally `cic_prompt.txt` in this project directory):

- Modify the ADRV9026 HDL reference design to add sample rate decimation in
  the receive path.
  - The carrier card is the ZCU102.
  - The evaluation board is the ADRV9029 evaluation board.

- Decimation supports:
  - Programmable decimation rates from 4 to 32.
  - Implemented using a combination of a CIC decimation filter and a fixed
    FIR compensation filter.
  - For now, only the CIC filter is implemented. The FIR compensation filter
    is future work.
  - All 4 complex receive channels use the same decimation rate.
  - The Xilinx CIC Compiler v4.0 is used for the CIC decimation filter (see
    `pg140-cic-compiler-en-us-4.0.pdf` in this directory).
  - Parameters:
    - CIC Decimation Filter
    - 5th order (N = 5)
    - Differential delay M = 1
    - 8 channels (4 complex channels, each with I & Q data)
    - Programmable rate change R, from 4 to 32
    - Input sample frequency 245.76 MSps
    - 16-bit input data samples (16-bit I and 16-bit Q)
    - 16-bit output data samples (16-bit I and 16-bit Q)
  - Decimated sample data is DMA'ed into processor memory.

- A bypass mode is supported that bypasses the decimation function and
  operates the same as the existing (pre-decimation) design.
  - Bypass mode is the default setting.

- Software:
  - Software can enable or disable bypass mode.
  - Software can set the decimation rate for the decimation filter.

- The block design supports a single link connection to the ADRV9026, with
  RX OBS channels disabled. This is the default configuration of the block
  design.

- Miscellaneous:
  - Xilinx Vivado 2025.1 is used for the build.
  - No changes are required to the Linux drivers or device tree.

## Implementation summary

- New block-design proc `ad_add_cic_decimation_filter`
  (`projects/common/xilinx/adi_cic_filter_bd.tcl`) instantiates 8 independent
  single-channel Xilinx CIC Compiler v4.0 cores (one per real I/Q channel),
  each with a 2-way bypass mux (`library/common/ad_bus_mux.v`) selecting
  between the raw (bypass) sample and the CIC-decimated sample. A small
  sequencer module (`projects/common/xilinx/cic_cfg_seq.v`) broadcasts the
  decimation rate to all 8 CIC cores via their `s_axis_config` channel and
  issues a brief reset pulse whenever the rate changes.
- New AXI-lite peripheral `library/axi_cic_decimate_ctrl/` holds the
  bypass-enable and decimation-rate control registers (see below), built on
  the repo's standard `up_axi`/`up_xfer_cntrl` primitives.
- The decimator sits between `rx_adrv9026_tpl_core` (JESD204 transport layer,
  per-converter parallel samples) and `util_adrv9026_rx_cpack` (the channel
  packer feeding `axi_dmac`) in `projects/adrv9026/common/adrv9026_bd.tcl`.
  No changes were needed to `axi_dmac` or `util_cpack2` — the packer's
  `fifo_wr_en` strobe already tolerates an intermittent (decimated) rate.
- This only applies to the project's default configuration: single JESD204
  link, RX-OBS (ORX) disabled (`ORX_ENABLE=0`). The separate RX-OBS datapath
  is untouched.
- No Linux driver or device-tree changes are required: the new control
  registers are a plain AXI-lite peripheral reachable from Linux userspace
  via `/dev/mem`/`devmem` at a fixed physical address (see below).

## AXI-lite control registers (`axi_cic_decimate_ctrl`)

- HDL/Vivado base address: `0x44AB0000`
- Physical address seen by Linux on this Zynq UltraScale+ target (ZCU102):
  `0x84AB0000` (HDL base `+ 0x40000000`)
- Register file: `library/axi_cic_decimate_ctrl/axi_cic_decimate_ctrl_reg.v`

| Byte offset | Word addr | Name        | Access | Reset      | Description |
|-------------|-----------|-------------|--------|------------|--------------|
| `0x00`      | `0x00`    | `VERSION`   | RO     | `0x00010000` | Core version. |
| `0x04`      | `0x01`    | `SCRATCH`   | RW     | `0x00000000` | Scratch register, no functional effect. |
| `0x40`      | `0x10`    | `CIC_RATE`  | RW     | `0x00000004` | Decimation rate. Bits `[7:0]` = rate value (valid range 4–32); bits `[31:8]` reserved/read as 0. |
| `0x44`      | `0x11`    | `CIC_CONFIG`| RW/RO  | `0x00000001` | Bit `[0]` `BYPASS_ENABLE` (RW) — 1 = bypass (raw, undecimated samples, default/reset state), 0 = decimation enabled. Bit `[1]` `BUSY` (RO) — 1 while a rate/reset reconfiguration sequence is in progress on the device-clock side; software should avoid relying on freshly-decimated data until this reads 0 after a rate change. Bits `[31:2]` reserved/read as 0. |

Notes:

- `CIC_RATE` and `CIC_CONFIG` bit 0 (`BYPASS_ENABLE`) are transferred from the
  AXI-lite clock domain into the RX device-clock domain as one atomic word
  (via `up_xfer_cntrl`), so a rate change and a bypass change written in the
  same AXI transaction are never torn.
- All 4 complex (8 real) RX channels always use the same decimation rate;
  there is a single `CIC_RATE` register, not one per channel.
- Example (Linux userspace, root, `CONFIG_STRICT_DEVMEM` permitting): set the
  rate to 8 and disable bypass —
  ```
  devmem 0x84AB0040 32 0x00000008   # CIC_RATE = 8
  devmem 0x84AB0044 32 0x00000000   # CIC_CONFIG: BYPASS_ENABLE=0, i.e. decimation on
  devmem 0x84AB0044                 # poll until bit 1 (BUSY) reads 0
  ```
  Re-enable bypass (back to today's original, undecimated behavior):
  ```
  devmem 0x84AB0044 32 0x00000001
  ```

## Rebuilding the FPGA from scratch

1. Source the Vivado 2025.1 environment:
   ```
   source /home/nriedel/xilinx/vivado/2025.1/Vivado/settings64.sh
   ```
2. From this project directory (`projects/adrv9026/zcu102`), do a clean
   build using the project's default parameters (single JESD204 link,
   `ORX_ENABLE=0` — the configuration this feature targets):
   ```
   cd /home/nriedel/projects/galt/hw/hdl/projects/adrv9026/zcu102
   make clean
   make
   ```
   No parameter overrides are needed for the default config; the new
   `axi_cic_decimate_ctrl` library IP is built automatically as part of the
   project build because it's listed in this project's `Makefile`
   (`LIB_DEPS += axi_cic_decimate_ctrl`).
3. Optional fast sanity check before a full build (packages/validates just
   the library IP dependencies, including the new `axi_cic_decimate_ctrl`
   core, without running synthesis/implementation):
   ```
   make lib
   ```
4. On success, the outputs are:
   - `adrv9026_zcu102.sdk/system_top.xsa`
   - `adrv9026_zcu102.runs/impl_1/system_top.bit`
5. To rebuild without disturbing an existing build in this directory, pass
   any parameter override (even one already equal to its default) to build
   into an isolated subdirectory instead, e.g.:
   ```
   make ORX_ENABLE=0
   ```
   This lands the build under `ORXENABLE0/` instead of the project root.
6. A known-good build of this change was last verified with `make ORX_ENABLE=0`
   as above: synthesis and implementation completed with 0 errors, 8 expected
   critical warnings (from the CIC reset-sequencer FSM not being recognized
   as a standard reset network by Vivado's heuristic reset-pin check — not a
   functional issue), and post-route timing closed with WNS = +0.050 ns,
   TNS = 0.000 ("All user specified timing constraints are met").
