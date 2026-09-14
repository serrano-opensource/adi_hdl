# ADRV9026 ZCU102 — CIC Decimation (RX) and Interpolation (TX)

## Original requirements — RX decimation

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

## Original requirements — TX interpolation

The mirror-image feature on transmit (originally `cic_interp_prompt.txt` in
this project directory):

- Modify the ADRV9026 HDL reference design to add sample rate interpolation
  in the transmit path (same carrier card and evaluation board as above).
- Interpolation supports:
  - Programmable interpolation rates from 4 to 32.
  - Implemented using a combination of a CIC interpolation filter and a fixed
    FIR compensation filter; for now, only the CIC filter is implemented.
  - All 4 complex transmit channels use the same interpolation rate.
  - Same Xilinx CIC Compiler v4.0 parameters as the RX decimator: 5th order
    (N = 5), differential delay M = 1, 8 channels (4 complex, I & Q each),
    programmable rate 4–32, 245.76 MSps, 16-bit input/output samples.
  - Transmit sample data is DMA'ed from processor memory, through the
    interpolator, and on to the ADRV9029 evaluation board.
  - A bypass mode is supported (default setting), operating the same as the
    existing pre-interpolation design.
- Software:
  - Software can enable/disable bypass and set the interpolation rate.
  - Reuses the same register block used for the RX decimation function
    (rather than a new/separate peripheral).
- Same miscellaneous constraints as RX: Vivado 2025.1, no Linux driver or
  device-tree changes, default single-link/RX-OBS-disabled configuration.

## Implementation summary

- New block-design proc `ad_add_cic_decimation_filter` (RX) and its TX
  counterpart `ad_add_cic_interpolation_filter`, both in
  `projects/common/xilinx/adi_cic_filter_bd.tcl`, each instantiate up to 8
  independent single-channel Xilinx CIC Compiler v4.0 cores (one per real I/Q
  channel; see "Resource-reduction follow-on" below for how only a subset of
  these actually get real hardware in the current default configuration) with
  a 2-way bypass mux (`library/common/ad_bus_mux.v`) per channel, and share
  one small sequencer module
  (`projects/common/xilinx/cic_cfg_seq.v`, reused unchanged for both
  directions) that broadcasts the rate to all 8 CIC cores via their
  `s_axis_config` channel and issues a brief reset pulse whenever the rate
  changes.
- The two directions are **not** wired identically, because decimation and
  interpolation naturally gate opposite sides of the datapath:
  - **RX decimation** muxes on the CIC's **output**: the input side is a
    continuous full-rate stream (`adc_data_$i`/`adc_valid_0`), and the CIC's
    own `m_axis_data_tvalid` naturally pulses at the decimated (slower) rate,
    which becomes the packer's `fifo_wr_en`.
  - **TX interpolation** muxes on the CIC's **input pop-request**: the
    downstream JESD204 TX transport layer (`tx_adrv9026_tpl_core`) has no
    backpressure and must be fed a sample every device-clock cycle
    unconditionally, so the CIC's `m_axis_data_tdata` feeds it directly with
    no gating. The **input** side instead ties `s_axis_data_tvalid` high
    permanently (the upstream `util_adrv9026_tx_upack/fifo_rd_data_$i` bus is
    held/registered, so it's always safe to present) and uses the CIC's own
    `s_axis_data_tready` (which asserts only once every R cycles) to drive
    `util_adrv9026_tx_upack/fifo_rd_en` — pulling one new sample from the
    DMA/unpack chain only as often as the interpolator actually consumes one.
    In bypass mode, `fifo_rd_en` is instead driven by `dac_valid_0` (the
    TPL's own continuous per-cycle strobe), reproducing today's original
    behavior exactly.
- One shared AXI-lite peripheral, `library/axi_cic_decimate_ctrl/`
  (instantiated as `axi_adrv9026_cic_ctrl`), holds **independent** bypass-enable
  and rate control registers for both RX and TX (see register table below),
  built on the repo's standard `up_axi`/`up_xfer_cntrl` primitives. RX and TX
  device clocks are confirmed-separate clock domains (independent
  `axi_clkgen`/MMCM instances, nominally the same frequency but with no fixed
  phase relationship), so the peripheral uses two independent
  `up_xfer_cntrl` clock-domain-crossing legs — one per direction — off one
  shared AXI-lite register bank.
- The RX decimator sits between `rx_adrv9026_tpl_core` (JESD204 RX transport
  layer) and `util_adrv9026_rx_cpack` (feeding `axi_dmac`); the TX
  interpolator sits between `util_adrv9026_tx_upack` (fed from `axi_dmac` via
  the data-offload core) and `tx_adrv9026_tpl_core` (JESD204 TX transport
  layer) — both in `projects/adrv9026/common/adrv9026_bd.tcl`. No changes
  were needed to `axi_dmac`, `util_cpack2`, or `util_upack2` themselves.
- This only applies to the project's default configuration: single JESD204
  link, RX-OBS (ORX) disabled (`ORX_ENABLE=0`). The separate RX-OBS datapath
  is untouched.
- No Linux driver or device-tree changes are required: the control registers
  are a plain AXI-lite peripheral reachable from Linux userspace via
  `/dev/mem`/`devmem` at a fixed physical address (see below).
- **Accepted TX rate-change transient**: unlike RX (which can simply pause
  its DMA write during the CIC reset/reconfig window), the JESD204 TX link
  has no backpressure, so a live interpolation-rate change while
  interpolation is active (not bypass toggling — just changing the rate) can
  put a handful of stale/settling samples on the TX output for a few cycles
  while the CIC core resets and refills. This is accepted as-is: it's an
  infrequent, deliberate, operator-triggered event, and both bypass mode and
  steady-state interpolation are unaffected.

## Resource-reduction follow-on: single active channel per direction

After the TX interpolation feature above was hardware-verified, a follow-on
change reduced FPGA resource usage by giving real `cic_compiler` hardware to
only a subset of the 8 real (I/Q) channels per direction, rather than all 8.
This was motivated purely by BOM/resource cost: the 16 `cic_compiler`
instances (8 RX + 8 TX) from the fully-populated design were, at ~8 DSP48E2
slices each, the dominant resource cost of this whole feature (128 DSP48E2
used in the fully-populated, hardware-verified build — see "Build status"
below for the before/after utilization numbers).

- **What "one channel" means.** In this project's terminology (from
  `cic_prompt.txt`/`cic_interp_prompt.txt`: "4 complex channels", "8 channels
  (4 complex channels each having I & Q data)"), one **complex** channel is
  both its I and Q real converters together — filtering I but not Q at the
  same rate would corrupt the complex signal. The 8 real converter indices
  are **interleaved** I/Q pairs, not grouped: real converter index `i`
  belongs to complex channel `i/2`, I if `i` is even, Q if `i` is odd. This
  mapping is confirmed via the paired Linux IIO driver (`adrv9025_conv.c` for
  RX, `cf_axi_dds.c` for TX — outside this HDL repo, and not documented
  anywhere in it). So keeping real indices `{0,1}` active means complex
  channel 0 (I0/Q0) gets real CIC hardware.
- **New parameter.** Both `ad_add_cic_decimation_filter` and
  `ad_add_cic_interpolation_filter` (in
  `projects/common/xilinx/adi_cic_filter_bd.tcl`) take a new second
  positional argument, `n_active_chan`, alongside the existing `n_chan`
  (total channel count). For real channel index `i < n_active_chan`,
  everything is unchanged: a real `cic_compiler` instance is instantiated and
  wired exactly as before. For `i >= n_active_chan`, no `cic_compiler`
  instance is created at all — this is where the DSP/LUT savings come from.
  `projects/adrv9026/common/adrv9026_bd.tcl` sets `RX_CIC_ACTIVE_CHANNELS`
  and `TX_CIC_ACTIVE_CHANNELS` to `2` (i.e. real indices `0`/`1`, complex
  channel 0 only) at both call sites; raising either back to 8 restores full
  8-channel CIC hardware for that direction with no other code changes.
- **Mechanism — repoint one mux input, no new control logic.** Every
  channel, active or not, already had a per-channel 2-way bypass mux
  (`out_mux_$i`, `library/common/ad_bus_mux.v`) whose `select_path` is driven
  by `bypass` and whose two inputs are the real CIC output (`data_in_0`, and
  on RX also `valid_in_0`) and the raw passthrough (`data_in_1`). For
  `i >= n_active_chan`, `data_in_0` (RX: and `valid_in_0`) is tied to a
  constant `GND` instead of being driven from a per-channel CIC core; the
  passthrough input and `select_path` are untouched for every channel. This
  single existing mux already gives exactly the desired behavior once its
  zero-rate input is repointed:
  - **`bypass = 1` (default)**: all 8 real channels pass raw data through
    unchanged, exactly as before this change — inactive channels are
    indistinguishable from active ones in bypass mode.
  - **`bypass = 0`**: active channels (real indices `0`/`1`) output a real
    decimated/interpolated value; every other channel outputs a constant
    zero.
  - Every top-level hier pin (`valid_in_$i`/`enable_in_$i`/`valid_out_$i`/
    `enable_out_$i`/`data_in_$i`/`data_out_$i`) is still created for every
    index `0..n_chan-1` regardless of active/inactive, so the DMA-facing
    wiring in `adrv9026_bd.tcl`, the register map, and the software view are
    all bit-for-bit unchanged. `cic_cfg_seq` and (on TX) `rden_mux` needed no
    changes: both already only reference index 0, which remains active.
- **A real bug found and fixed while implementing this.** Tying `data_in_0`/
  `valid_in_0` to `GND` for an inactive channel connects a root-level
  constant cell directly into a pin nested two hierarchy levels down
  (`$name/out_mux_$i/data_in_0`, where `out_mux_$i` is a child cell of the
  filter's own hierarchy `$name`). The first time this happens for a given
  constant width, Vivado's `connect_bd_net` silently auto-creates a hidden
  boundary pin on `$name` to route the signal in, named after the
  destination's own leaf pin name with an auto-incrementing suffix on
  collision (e.g. tying `out_mux_1/valid_in_0` to `GND` auto-created a
  phantom pin literally named `valid_in_2` on the filter hierarchy) — which
  then collided with this same loop's own `create_bd_pin` call for that
  later channel index, failing with `Specified object '.../valid_in_2'
  already exists`. This was reproduced in isolation (a minimal standalone
  block design hitting the identical failure) before being root-caused.
  Fixed by wrapping the per-channel `GND` ties in both procs with
  `current_bd_instance [get_bd_cells $name]` / `current_bd_instance /`, so
  the constant cell is created *inside* the filter's own hierarchy instead
  of crossing into it — same-level connections don't trigger Vivado's
  auto-boundary-pin behavior. This is a latent Vivado behavior, not
  something specific to `n_active_chan`; the pre-existing (unconditional)
  `GND` ties in the TX interpolator's `rden_mux` setup and per-channel loop
  hit the same mechanism but happened to reuse an already-created constant
  cell (from an unrelated earlier tie) in every case that mattered, so they
  never collided with a real pin name and were left as-is.

## AXI-lite control registers (`axi_cic_decimate_ctrl`, instantiated as `axi_adrv9026_cic_ctrl`)

- HDL/Vivado base address: `0x44AB0000`
- Physical address seen by Linux on this Zynq UltraScale+ target (ZCU102):
  `0x84AB0000` (HDL base `+ 0x40000000`)
- Register file: `library/axi_cic_decimate_ctrl/axi_cic_decimate_ctrl_reg.v`

| Byte offset | Word addr | Name            | Access | Reset        | Description |
|-------------|-----------|-----------------|--------|--------------|--------------|
| `0x00`      | `0x00`    | `VERSION`       | RO     | `0x00010000` | Core version. |
| `0x04`      | `0x01`    | `SCRATCH`       | RW     | `0x00000000` | Scratch register, no functional effect. |
| `0x40`      | `0x10`    | `RX_CIC_RATE`   | RW     | `0x00000004` | RX decimation rate. Bits `[7:0]` = rate value (valid range 4–32); bits `[31:8]` reserved/read as 0. |
| `0x44`      | `0x11`    | `RX_CIC_CONFIG` | RW/RO  | `0x00000001` | Bit `[0]` `BYPASS_ENABLE` (RW) — 1 = bypass (raw, undecimated RX samples, default/reset state), 0 = decimation enabled. Bit `[1]` `BUSY` (RO) — 1 while an RX rate/reset reconfiguration is in progress. Bits `[31:2]` reserved/read as 0. |
| `0x48`      | `0x12`    | `TX_CIC_RATE`   | RW     | `0x00000004` | TX interpolation rate. Same bit layout as `RX_CIC_RATE`. |
| `0x4C`      | `0x13`    | `TX_CIC_CONFIG` | RW/RO  | `0x00000001` | Same bit layout as `RX_CIC_CONFIG`: bit `[0]` `BYPASS_ENABLE` (1 = bypass/default), bit `[1]` `BUSY` (RO). |

Notes:

- Each direction's `*_CIC_RATE` and `*_CIC_CONFIG` bit 0 (`BYPASS_ENABLE`) are
  transferred from the AXI-lite clock domain into that direction's own
  device-clock domain as one atomic word (via a dedicated `up_xfer_cntrl`
  instance per direction), so a rate change and a bypass change written in
  the same AXI transaction are never torn, and RX/TX reconfiguration never
  interfere with each other.
- RX and TX rates/bypass are fully independent — setting one does not affect
  the other. All 4 complex channels within a given direction always share
  that direction's single rate register; there is no per-channel rate. Since
  the "Resource-reduction follow-on" change below, only the active
  channel(s) actually have real CIC hardware to apply this rate to — the
  rate register still exists and is still written the same way for every
  channel, but has no observable effect on inactive channels (they output
  zero whenever bypass is disabled, regardless of rate).
- Example (Linux userspace, root, `CONFIG_STRICT_DEVMEM` permitting): set the
  RX decimation rate to 8 and disable RX bypass —
  ```
  devmem 0x84AB0040 32 0x00000008   # RX_CIC_RATE = 8
  devmem 0x84AB0044 32 0x00000000   # RX_CIC_CONFIG: BYPASS_ENABLE=0, i.e. decimation on
  devmem 0x84AB0044                 # poll until bit 1 (BUSY) reads 0
  ```
  Set the TX interpolation rate to 8 and disable TX bypass:
  ```
  devmem 0x84AB0048 32 0x00000008   # TX_CIC_RATE = 8
  devmem 0x84AB004C 32 0x00000000   # TX_CIC_CONFIG: BYPASS_ENABLE=0, i.e. interpolation on
  devmem 0x84AB004C                 # poll until bit 1 (BUSY) reads 0
  ```
  Re-enable bypass on either direction (back to today's original behavior):
  ```
  devmem 0x84AB0044 32 0x00000001   # RX bypass on
  devmem 0x84AB004C 32 0x00000001   # TX bypass on
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
   No parameter overrides are needed for the default config; the
   `axi_cic_decimate_ctrl` library IP is built automatically as part of the
   project build because it's listed in this project's `Makefile`
   (`LIB_DEPS += axi_cic_decimate_ctrl`).
3. Optional fast sanity check before a full build (packages/validates just
   the library IP dependencies, including `axi_cic_decimate_ctrl`, without
   running synthesis/implementation):
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
6. Build status: the RX decimator was hardware-verified (commit `902af7e95`,
   "Basic CIC decimator working on HW."). Adding the TX interpolator and
   extending the shared control peripheral was first verified with a full
   synthesis/implementation/bitstream build (`make ORX_ENABLE=0`, Vivado
   2025.1): 0 errors throughout, `write_bitstream` completed successfully,
   and post-route timing closed with WNS = +0.052 ns, TNS = 0.000. At the
   time, the 16 critical warnings in that build were assumed (never actually
   inspected) to be the same "reset pin ... asynchronous reset source"
   heuristic seen during `validate_bd_design` — this turned out to be
   inaccurate; see "Known issues" below.
7. First-round TX hardware bring-up found a functional bug — a
   rate-independent 8x-too-slow output frequency (see "Known issues (fixed)"
   below: wrong `SamplePeriod`). Fixing it and rebuilding surfaced two more
   things, both also fixed in source (see "Known issues" below): the
   critical warnings were actually a different, genuine issue in
   `cic_cfg_seq.v` (not the BD-time reset-pin heuristic as previously
   assumed), and the larger CIC interpolator hardware footprint from the
   `SamplePeriod` fix perturbed placement enough to fail timing by a small
   margin in an unrelated, pre-existing `axi_dmac` path.
8. Rebuilt with all three fixes applied (`SamplePeriod`, `cic_cfg_seq`
   reset value, `cic_cfg_seq` config-source): full synthesis/implementation/
   bitstream build, Vivado 2025.1, `make ORX_ENABLE=0` — **0 errors, 0
   critical warnings** (down from 16–18; the `cic_cfg_seq` fix eliminated
   the "cannot be timed accurately" warnings entirely), `write_bitstream`
   completed successfully, and post-route timing closed cleanly: WNS =
   +0.051 ns, TNS = 0.000, 0 failing endpoints — "All user specified timing
   constraints are met." This also confirms the `axi_dmac` timing miss from
   the intermediate build was placement noise from the larger netlist, not
   a fundamental conflict: the smaller, cleaner netlist from the
   `cic_cfg_seq` fix closed timing again on its own. This build's
   utilization report (`system_top_utilization_placed.rpt`) is the
   fully-populated (8 active channels per direction) baseline referenced in
   "Resource-reduction follow-on" above: **128 DSP48E2 used, 16
   `cic_decimator_*`/`cic_interpolator_*` instances**. **Still outstanding**:
   a hardware retest repeating the original tone-injection measurement, to
   confirm the `SamplePeriod` fix actually produces the correct frequency
   at each rate (everything above is build/synthesis-level verification
   only).
9. Resource-reduction follow-on (`RX_CIC_ACTIVE_CHANNELS`/
   `TX_CIC_ACTIVE_CHANNELS = 2`, i.e. one active complex channel per
   direction): BD-level validation (`validate_bd_design` plus
   `generate_target`, isolated scratch project) passed with 0 errors and
   only 4 critical warnings — the same benign "reset pin ... asynchronous
   reset source" `validate_bd_design`-time heuristic seen throughout this
   feature's earlier builds, now one per active `cic_compiler` instance (2
   RX + 2 TX, down from 8 + 8).

   A full synthesis/implementation/bitstream rebuild (`make ORX_ENABLE=0`)
   confirmed the resource savings — **44 DSP48E2 used, 4
   `cic_decimator_*`/`cic_interpolator_*` instances**, down from the
   fully-populated baseline's 128 DSP48E2 / 16 instances (item 8 above) —
   with 0 errors and 0 critical warnings, and `write_bitstream` completed
   successfully. The first attempt with this project's existing
   `Performance_RefinePlacement` implementation strategy, however, narrowly
   **missed timing**: WNS = -0.018 ns, TNS = -0.075 ns, 7 failing endpoints,
   all on the same stock, unmodified `axi_adrv9026_tx_dma` internal
   store-and-forward path already called out as a pre-existing, tight-margin
   path in item 7 above — the smaller CIC netlist shifted placement enough
   to eat into that margin again, the same mechanism as before but landing
   unfavorably this time instead of favorably. Per item 8's own prediction
   ("a timing-driven implementation strategy change would be the next thing
   to try"), that's what closed it: re-running implementation (place, route,
   bitstream — from the same synthesized netlist, so equivalent to a full
   rebuild) with strategy `Performance_ExplorePostRoutePhysOpt` in place of
   `Performance_RefinePlacement` closed timing cleanly — WNS = +0.013 ns,
   TNS = 0.000 ns, 0 failing endpoints, 0 critical warnings.
   `projects/adrv9026/zcu102/system_project.tcl`'s `set_property strategy`
   line was updated to this new strategy so a plain `make`/`make
   ORX_ENABLE=0` closes timing on the reduced-channel design without a
   manual re-run.

   A real Vivado BD-scripting bug was also found and fixed while
   implementing this: see "Resource-reduction follow-on" above ("A real bug
   found and fixed while implementing this") for the cross-hierarchy `GND`
   auto-boundary-pin issue and its fix.

   **Still outstanding**: the hardware retest described in the
   "Verification" section of this change (channel 0 still correct, bypass
   still passes all 8 channels, inactive channels read back as zero with
   bypass disabled) — see item 10 below for a related hardware finding
   made while pursuing this.

10. **Hardware regression found and fixed: `axi_adrv9026_cic_ctrl`
    (`axi_cic_decimate_ctrl`) became completely unresponsive on real
    hardware after item 9's resource reduction, root-caused to a missing
    CDC timing constraint — not a logic bug.** After flashing item 9's
    bitstream, `devmem` reads/writes to `axi_adrv9026_cic_ctrl`'s registers
    (base `0x84AB0000`) failed with a bus error on read and a kernel panic
    on write, at every offset tried (including `VERSION`, a pure
    combinational readback) — while other, unrelated PL peripherals on the
    same PS AXI-lite master port (`M_AXI_HPM0_LPD`) continued to work fine.
    Extensive static analysis (BD address-map export, routed-checkpoint
    netlist inspection of `axi_adrv9026_cic_ctrl`'s reset/clock/AXI-handshake
    signals) found nothing wrong — reset, clock, and every `s_axi_*`
    handshake signal were driven normally, none tied to a constant. A
    bisection rebuild (isolated to a throwaway git worktree, restoring
    `RX_CIC_ACTIVE_CHANNELS`/`TX_CIC_ACTIVE_CHANNELS` to 8 while keeping
    everything else from item 9 identical) confirmed `devmem` worked
    correctly with the full 8-channel CIC hardware present, proving the
    regression was caused specifically by the channel-count reduction
    itself, not the `Performance_ExplorePostRoutePhysOpt` strategy change
    from item 9.

    Root cause: `library/axi_cic_decimate_ctrl/axi_cic_decimate_ctrl_ip.tcl`
    never included `library/xilinx/common/up_xfer_cntrl_constr.xdc` — the
    standard constraint file that declares `ASYNC_REG TRUE` on the
    toggle-synchronizer flops in `library/common/up_xfer_cntrl.v` and
    excepts the crossing with `set_false_path`. Every other IP in this
    repo that reuses `up_xfer_cntrl.v` (e.g. `axi_ad9265`, `axi_adc_trigger`,
    dozens of others) bundles this constraint file alongside the source;
    `axi_cic_decimate_ctrl` (added in this feature's Phase B, well before
    the resource-reduction work) never did. Without `ASYNC_REG`, Vivado's
    placer had no reason to keep `axi_adrv9026_cic_ctrl`'s two
    `up_xfer_cntrl` instances' synchronizer stages (`i_xfer_cntrl` for RX,
    `i_tx_xfer_cntrl` for TX) physically close together, and without
    `set_false_path`, the crossing between `up_clk` and `dec_clk`/`tx_clk`
    was left for ordinary (and, for a genuine clock-domain crossing,
    inappropriate) timing analysis rather than being properly excepted.
    This latent gap had been present since Phase B and evidently never
    caused an observable failure until the resource reduction's much
    smaller CIC netlist (128 → 44 DSP48E2) shifted the floorplan enough to
    expose it, deterministically wedging the peripheral's AXI-lite
    interface on every access.

    Fix: added
    `"$ad_hdl_dir/library/xilinx/common/up_xfer_cntrl_constr.xdc"` to
    `axi_cic_decimate_ctrl_ip.tcl`'s `adi_ip_files` list, matching the
    established repo convention. Verified the library IP repackages with
    the constraint file present (`component.xml` now references it), then
    rebuilt the full 2-active-channel design: **0 errors, 0 critical
    warnings** (even better than item 9's build — the previously-seen
    benign "reset pin ... asynchronous reset source" warnings are gone
    too, plausibly because the `ASYNC_REG` declaration also satisfies that
    heuristic), and timing margin *improved* to **WNS = +0.048 ns** (up
    from item 9's +0.013 ns) — consistent with the missing exception
    having forced the tool to spend effort trying to satisfy an
    inappropriate synchronous timing requirement on those CDC paths.
    DSP48E2/instance counts unchanged from item 9 (44 DSP48E2, 4
    instances). **Confirmed on real hardware**: `devmem 0x84ab0040 32`
    reads and writes both work correctly with this build. The full
    tone-injection hardware retest from item 9's "Still outstanding" is
    still pending, but the specific regression this item describes is
    resolved.

## Known issues (fixed)

**TX interpolation output frequency was 8x too low, at every rate (fixed).**
During first hardware bring-up, injecting a period-25-sample complex
sinusoid gave the expected `245.76 MHz / 25 = 9.8304 MHz` tone in bypass
mode, confirming the baseline datapath and JESD204 TX chain are correct.
With bypass disabled, though, the observed output frequency was consistently
**8x lower** than expected (`9.8304 MHz / (25*R)`) — e.g. ~307 kHz instead of
2.4576 MHz at R=4, and ~156 kHz instead of 1.2288 MHz at R=8. The ratio was
constant across different R values, ruling out an R-dependent bug.

Root cause: `ad_add_cic_interpolation_filter` (in
`projects/common/xilinx/adi_cic_filter_bd.tcl`) configured each
`cic_compiler` instance's `SamplePeriod` (in `RateSpecification =
Sample_Period` mode) to `max_rate` (32). Per the CIC Compiler v4.0 product
guide (pg140), `SamplePeriod` is "the integer number of clock cycles between
input samples," and for a **Programmable**-rate core this static parameter
must be sized for the *fastest* (most demanding) rate in the configured
range — i.e. `min_rate` (4), not `max_rate`. `max_rate` was originally
chosen only because `SamplePeriod=1` was rejected by the IP with a range
error whose floor happened to equal `min_rate`, without working out why that
floor existed. The mismatch introduced a fixed, rate-independent extra
division of `max_rate / min_rate` = `32/4` = 8 on top of whatever rate was
configured at runtime — matching the observed symptom exactly. The RX
decimator does not have this bug: decimation's input always arrives every
clock cycle regardless of R, so `SamplePeriod=1` was already the correct
value there, with no equivalent "size for the fastest case" decision to get
wrong.

Fix: `SamplePeriod` now uses `$min_rate` instead of `$max_rate`. Verified
that `SamplePeriod=4` is accepted by the IP for this configuration and that
the block design still elaborates with 0 errors.

**`cic_cfg_seq`'s `rate_d` register was flagged "cannot be timed accurately"
(fixed) — and this was mischaracterized in this doc's earlier build-status
notes.** The `SamplePeriod` fix above changed the CIC cores' internal
resource layout enough that re-running the full build surfaced 16 critical
warnings whose actual content had never been inspected in either of the two
prior successful builds (RX-only, and RX+TX-with-the-8x-bug) — their counts
(8, then 16) had simply been *assumed* to match the `validate_bd_design`-time
"reset pin ... connected to asynchronous reset source" heuristic (one per
CIC core, one set per direction) without checking. They were not: the actual
implementation-level warning was `Reg '.../cfg_seq/inst/rate_d_reg[N]' of
type 'FDCPE' cannot be timed accurately`, one per bit of `rate_d`, one set
per direction (`RATE_WIDTH`=8 bits × {RX, TX} = 16) — a pre-existing issue
in `cic_cfg_seq.v` present since the RX-only core was first written, that
had simply never been checked at this level of detail before.

Root cause: on `aresetn`, `cic_cfg_seq.v` reset `rate_d` to the live value of
the `rate` input (`rate_d <= rate;`) rather than to a constant. Resetting a
register to another (multi-bit, data-dependent) signal's value makes that
register's per-bit asynchronous clear/preset depend on that signal, which
Vivado's static timing analysis cannot verify recovery/removal timing for —
"hardware behavior may be unpredictable" per the tool's own warning text, a
materially more serious class of warning than the BD-time heuristic it had
been assumed to be.

Fix: reset `rate_d` to a plain constant (`'d0`) instead. Since `rate_d` is
only used for edge-detection in `ST_IDLE` (`if (rate_d != rate) ...`), not
as the actual value sent to the CIC cores, this is safe on its own — but it
would have left the very first post-reset config transaction sending an
invalid `RATE=0` (since that transaction, in `ST_RST`, previously sourced
`cfg_tdata_r` from `rate_d`, which is 0 immediately after reset and only
gets loaded from the live `rate` input once `ST_IDLE` is first reached).
Fixed that too: `ST_RST` now sources `cfg_tdata_r` directly from the live
`rate` input rather than from `rate_d`, so every config transaction (initial
power-up and any later rate change) always carries a valid rate. The net
effect is one extra, harmless redundant reconfiguration cycle immediately
after power-up (re-applying the already-correct initial rate a second time)
in exchange for eliminating the warning. This fix applies to both RX and TX,
since `cic_cfg_seq` is shared code, but does not change the RX decimator's
already-hardware-verified behavior (register offsets, reset values, and the
actual rate ultimately applied are all unchanged).

**The `SamplePeriod` fix's larger CIC hardware footprint marginally failed
timing in an unrelated, pre-existing path (rebuild triggered).** After the
`SamplePeriod` fix (above), a full rebuild reached `write_bitstream`
successfully but **did not close timing**: WNS = -0.063 ns, TNS = -0.545 ns,
24 failing endpoints (of 142,665). The failing paths are entirely inside the
stock, unmodified `axi_dmac` core (`axi_adrv9026_tx_dma`'s internal
store-and-forward BRAM path on the fixed ~333 MHz DMA clock) — nothing to do
with the CIC logic itself. Building each CIC interpolator core for the
fastest rate in its programmable range (per the `SamplePeriod` fix) requires
more internal hardware parallelism than building for the slowest rate did,
which shifted the overall floorplan enough to eat into an already-tight,
pre-existing margin elsewhere in the design. A rebuild (with the
`cic_cfg_seq` fix above also applied, which changes the netlist again and
may shift placement back) is the next step to see whether this closes on
its own; if not, a timing-driven implementation strategy change would be
the next thing to try.

**Re-verified**: a full synthesis/implementation/bitstream rebuild with all
three fixes applied confirmed 0 errors, 0 critical warnings, and timing
closed cleanly (WNS = +0.051 ns, TNS = 0.000) — see build status item 8
above. **Still outstanding**: a hardware retest (repeating the same
injected-tone measurement) to confirm the `SamplePeriod` fix actually
produces the correct frequency at each rate; everything above is
build/synthesis-level verification only.
