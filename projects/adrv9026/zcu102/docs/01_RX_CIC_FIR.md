# ADRV9026 RX CIC Decimation + FIR Compensation Filter

Adds programmable RX sample-rate decimation (5th-order CIC, rate 4–32) and
47-tap (24 independent coefficients) FIR droop-compensation filtering to
the ADRV9026/ZCU102 HDL reference design.

**Status as of this document:** CIC decimation is implemented and working
on all 8 real (I/Q) channels. FIR droop compensation is implemented,
scale-corrected, and verified end-to-end on **channels 0/1 only** (the
first complex RX channel). Channels 2–7 are decimated but not yet
FIR-filtered; see [Known Limitations](#known-limitations--open-items).
A pre-existing, unrelated TX-domain timing issue was also identified
during this work — see item 6 in that section.

---

## 1. Architecture Overview

```
                     ┌─────────────────────────────────────────────────────┐
 adc_data_$i ───────▶│  rx_cic_decimator (adi_cic_filter_bd.tcl)             │
                     │                                                       │
                     │  ┌────────────┐   ┌──────────┐   ┌─────────┐ ┌─────┐ │
                     │  │   CIC      │──▶│  bypass  │──▶│ (ch 0/1 │ │24→16│ │──▶ data_out_$i / fir_data_out_$i
                     │  │ Decimator  │   │   mux     │   │  only)  │ │ sat │ │
                     │  │ (8 chan)   │   └──────────┘   │   FIR    │ └─────┘ │
                     │  └────────────┘                  │Compiler  │        │
                     │                                  │(47 tap,  │        │
                     │                                  │ 24 coef) │        │
                     │                                  └─────────┘        │
                     └─────────────────────────────────────────────────────┘
                              ▲                    ▲
                     ┌────────┴────────┐  ┌────────┴──────────┐
                     │ cic_cfg_seq.v   │  │ fir_coef_seq.v     │
                     │ (rate/reset     │  │ (coefficient       │
                     │  broadcast)     │  │  reload sequencer, │
                     └────────┬────────┘  │  NUM_TAPS=24)      │
                              │           └────────┬───────────┘
                     ┌────────┴─────────────────────┴───────────┐
                     │   axi_adrv9026_rx_decimate_ctrl            │
                     │   (AXI-lite register file, see §3)         │
                     └─────────────────────────────────────────────┘
```

**Pipeline per channel (0/1 only):**
`ADC data → CIC decimation (rate 4–32) → [bypass mux] → 47-tap symmetric
FIR (droop correction, 24-bit internal accumulate) → 24→16 saturate →
[bypass mux] → packer / DMA`

**Pipeline per channel (2–7):**
`ADC data → CIC decimation (rate 4–32) → [bypass mux] → fir_chan_delay
(35-cycle latency match, no filtering) → packer / DMA`

### Why the FIR is "47-tap" but only 24 coefficients are loaded

The filter is generated with `Coefficient_Structure = Symmetric`
(`h[k] = h[46-k]` for `k = 0..46`), which roughly halves DSP48E2 usage
(25 vs. 48 per channel) by folding mirrored tap pairs onto shared
multipliers. Because of that symmetry, only the first 24 coefficients
(`h[0]` through `h[23]`, the center tap) are mathematically independent —
the core reconstructs the mirrored half internally and never asks for it
over the reload channel. **Confirmed directly from the generated core's
`_reload_order.txt`: reload index `k` = coefficient `k`, for `k = 0..23`,
no reordering.**

### Why channels 2–7 are delay-matched but not filtered

`util_adrv9026_rx_cpack` packs all 8 channels using **one shared
`fifo_wr_en` strobe** (not per-channel), sourced from channel 0. Since the
FIR core adds a fixed 35-cycle pipeline latency, channels 0/1's data
arrives 35 cycles later than it otherwise would. If channels 2–7 weren't
also delayed by the same amount, the packer would capture stale/misaligned
data on every sample. `fir_chan_delay.v` closes that gap without actually
filtering those channels.

### Why the FIR core's output is 24 bits internally, then saturated to 16

The FIR core's accumulator is 38 bits wide (sized for worst-case bit
growth, since `Coefficient_Reload = true`). With `Output_Width` originally
set to 16, the core extracted the top 16 bits of that accumulator —
discarding the bottom 22 bits. But the coefficients are Q1.14 fixed-point
(14 fractional bits, chosen because the center tap exceeds 1.0 and needs
headroom), not what that discard implicitly assumed. The mismatch
produced an output ~256× (exactly 2⁸) too small — confirmed by direct
simulation (see §4.2 below). **Fix:** `Output_Width` is now `24` (discard
`38 − 24 = 14` bits, matching the coefficients' real scale), and a new
combinational module, `fir_out_sat.v`, truncates/saturates that 24-bit
value back to a clean 16-bit sample for the rest of the datapath. This
stage adds **zero pipeline latency** (purely combinational), so no other
timing/latency numbers in this design changed because of it.

---

## 2. Files

| File | Location | Purpose |
|---|---|---|
| `adi_cic_filter_bd.tcl` | `projects/common/xilinx/` | Block-design proc `ad_add_cic_decimation_filter` — instantiates the CIC cores, FIR cores, sequencers, and all internal wiring |
| `adrv9026_bd.tcl` | `projects/adrv9026/common/` | Top-level integration — instantiates `rx_cic_decimator` and `axi_adrv9026_rx_decimate_ctrl`, wires them to the ADC/packer/DMA datapath |
| `cic_cfg_seq.v` | `projects/common/xilinx/` | CIC rate/reset broadcast sequencer (pre-existing) |
| `fir_coef_seq.v` | `projects/common/xilinx/` | FIR coefficient reload sequencer — streams `NUM_TAPS=24` taps over `S_AXIS_RELOAD`, then triggers `S_AXIS_CONFIG` |
| `fir_chan_delay.v` | `projects/common/xilinx/` | Dedicated 16-bit-wide N-cycle delay line, used to latency-match channels 2–7 |
| `fir_out_sat.v` | `projects/common/xilinx/` | Combinational 24→16-bit saturating truncate, corrects the FIR output scaling (see §1) |
| `util_delay.v` | `library/common/` | Pre-existing 1-bit delay utility, used to align the FIR's internal `enable` signal |
| `ad_bus_mux.v` | `library/common/` | Pre-existing combinational 2:1 mux, used for both CIC and FIR bypass selection |
| `axi_cic_decimate_ctrl.v` | `library/axi_cic_decimate_ctrl/` | AXI-lite peripheral top-level (instantiated in `adrv9026_bd.tcl` as `axi_adrv9026_rx_decimate_ctrl`). `NUM_TAPS` default = 24. |
| `axi_cic_decimate_ctrl_reg.v` | `library/axi_cic_decimate_ctrl/` | Register file — see §3 for the full map. `NUM_TAPS` default = 24. |
| `axi_cic_decimate_ctrl_ip.tcl` | `library/axi_cic_decimate_ctrl/` | IP packaging script — **must be re-run any time the register file's ports OR parameter defaults change** (see §5) |

---

## 3. Register Map

**Peripheral instance name:** `axi_adrv9026_rx_decimate_ctrl`
**HDL base address:** `0x44AB0000`
**Linux physical address (ZCU102):** `0x84AB0000`
**AXI address bus width:** 8 bits (byte address); word address is the
low 6 bits (`byte_addr >> 2`)

All registers are 32 bits wide, accessed as 32-bit words. Byte offset =
word address × 4.

| Word Addr | Byte Offset | Name | Access | Description |
|---|---|---|---|---|
| `0x00` | `0x00` | `VERSION` | RO | Peripheral version (`0x00010000`) |
| `0x01` | `0x04` | `SCRATCH` | RW | Scratch register, no function |
| `0x10` | `0x40` | `CIC_RATE` | RW | CIC decimation rate |
| `0x11` | `0x44` | `CIC_CONFIG` | RW/RO | CIC bypass + busy status |
| `0x20` | `0x80` | `FIR_COEF_DATA` | WO | Write one coefficient (auto-incrementing pointer) |
| `0x21` | `0x84` | `FIR_COEF_PTR_RST` | WO (strobe) | Reset the coefficient write pointer to 0 |
| `0x22` | `0x88` | `FIR_LOAD` | WO (strobe) | Trigger the FIR reload sequencer |
| `0x23` | `0x8C` | `FIR_CONFIG` | RW/RO | FIR bypass + busy status |
| `0x24` | `0x90` | `FIR_COEF_COUNT` | RO | Current coefficient write pointer (verification aid) |

### `CIC_RATE` (0x40) — RW

| Bits | Name | Description |
|---|---|---|
| `[7:0]` | `RATE` | Decimation rate, valid range 4–32. Reset value: 4. |
| `[31:8]` | — | Reserved |

### `CIC_CONFIG` (0x44) — RW/RO

| Bits | Name | Access | Description |
|---|---|---|---|
| `[0]` | `BYPASS_ENABLE` | RW | 1 = raw ADC passthrough (no decimation). **Reset value: 1** (bypassed by default). 0 = CIC decimation active. |
| `[1]` | `BUSY` | RO | 1 while the CIC cores are being reset/reconfigured after a rate change |
| `[31:2]` | — | Reserved |

### `FIR_COEF_DATA` (0x80) — WO

| Bits | Name | Description |
|---|---|---|
| `[15:0]` | `COEF` | Signed 16-bit coefficient value (Q1.14 fixed-point, see §4.2). Written to the register file's internal **24**-entry array at the current pointer; pointer then auto-increments. |
| `[31:16]` | — | Ignored on write |

**Pointer behavior:** the write pointer saturates at `NUM_TAPS-1` (**23**,
corrected from the previously documented 46) — it does **not** wrap back
to 0. Writing more than 24 times overwrites the last tap repeatedly
rather than corrupting an earlier one.

### `FIR_COEF_PTR_RST` (0x84) — WO, strobe

Any write (value ignored) resets the coefficient pointer to 0. **Must be
written before starting a fresh 24-word load** — the pointer is never
implicitly reset any other way (not by `FIR_LOAD`, not by finishing a
previous load), so every load sequence is self-contained and restart-safe
regardless of how a prior load left the pointer.

### `FIR_LOAD` (0x88) — WO, strobe

Any write (value ignored) triggers `fir_coef_seq` to stream the current
24-entry coefficient array out to both FIR cores (`S_AXIS_RELOAD`) and
then issue the `S_AXIS_CONFIG` synchronization pulse that makes the new
coefficients take effect. Poll `FIR_CONFIG.BUSY` (below) to know when this
has completed.

### `FIR_CONFIG` (0x8C) — RW/RO

| Bits | Name | Access | Description |
|---|---|---|---|
| `[0]` | `BYPASS_ENABLE` | RW | 1 = raw CIC-output passthrough (FIR not in the signal path). **Reset value: 1** (bypassed by default). 0 = FIR compensation active. |
| `[1]` | `BUSY` | RO | 1 while `fir_coef_seq` is streaming a reload (i.e. between a `FIR_LOAD` write and reload+sync completion) |
| `[31:2]` | — | Reserved |

### `FIR_COEF_COUNT` (0x90) — RO

| Bits | Name | Description |
|---|---|---|
| `[5:0]` | `COUNT` | Current coefficient write pointer value |
| `[31:6]` | — | Reserved |

**Reading this after a full 24-word load returns `23` (`0x17`), not
`24`** — the pointer saturates at `NUM_TAPS-1`, so `23` is the
correct/expected value confirming a complete load. A lower value means
fewer than 24 words were written.

---

## 4. Usage

### 4.1 Enabling CIC decimation

```
write CIC_RATE   = <4..32>
write CIC_CONFIG = 0x0        // clears BYPASS_ENABLE, enables decimation
poll  CIC_CONFIG.BUSY until 0
```

### 4.2 Loading FIR coefficients (channels 0/1 only)

```
write FIR_COEF_PTR_RST = <any value>      // reset pointer to 0
repeat 24 times:
  write FIR_COEF_DATA = <next coefficient, signed 16-bit>
read  FIR_COEF_COUNT                       // expect 23 (0x17) — confirms all 24 written
write FIR_LOAD = <any value>               // trigger reload
poll  FIR_CONFIG.BUSY until 0              // wait for reload + sync to complete
write FIR_CONFIG = 0x0                      // clears BYPASS_ENABLE, enables FIR
```

**Coefficient order — confirmed, no reordering needed.** Write index `k`
of the loop above (`k = 0..23`) is coefficient `h[k]` directly — the
`_reload_order.txt` file generated for this core's configuration
(`Coefficient_Sets=1`, `Symmetric`) confirms `Reload index k = Coefficient
k` for the full independent range. The mirrored second half
(`h[24]..h[46] = h[22]..h[0]`) is never written; the hardware reconstructs
it from the symmetric structure.

**The actual droop-correction coefficient set** (Q1.14 fixed-point, i.e.
each value = `round(ideal_coefficient × 16384)`), to write in order for
`k = 0` to `23`:

```
k=0:  -133      k=6:   504      k=12: -1269     k=18:  3460
k=1:   173      k=7:  -707      k=13:  1822     k=19: -5444
k=2:  -233      k=8:   739      k=14: -1978     k=20:  6409
k=3:   159      k=9:  -537      k=15:  1541     k=21: -4759
k=4:    -3      k=10:   86      k=16:  -419     k=22: -3090
k=5:  -241      k=11:  560      k=17: -1332     k=23: 25584  (center tap)
```

These are already correctly scaled for direct use — write them exactly
as-is via `FIR_COEF_DATA`. No firmware-side rescaling is needed; the
`Output_Width=24` + `fir_out_sat.v` fix (§1) handles the Q1.14 alignment
entirely inside the FPGA. A constant-DC-input simulation of this exact
coefficient set (via a standalone scratch IP + testbench, `fir_scale_check`
/ `fir_scale_check_tb.v`) measured a steady-state gain of 0.989 for an
input of 1000 (output 989) — matching the hand-calculated expected gain
(`16200/16384 ≈ 0.989`, from the sum of the raw coefficients) almost
exactly, confirming the scaling fix is correct.

### 4.3 FIR reset behavior — reload after power-up

The FIR cores use their own reset (`fir_rstgen`), deliberately independent
of the CIC's rate-change reset (see §5 for why). This reset only fires
once, at system power-up. **After every power-up/reset, firmware must
perform a full coefficient load (§4.2) before the FIR will produce correct
output** — this is the same requirement as loading coefficients for the
first time, not an extra step.

### 4.4 Bypass control summary

| Register | Bit | Effect when set to 1 |
|---|---|---|
| `CIC_CONFIG` | `BYPASS_ENABLE` | Raw ADC data passed through, no decimation, on **all 8 channels** |
| `FIR_CONFIG` | `BYPASS_ENABLE` | CIC output passed through unfiltered, on **channels 0/1 only** (channels 2–7 are never filtered regardless of this bit) |

Both bypass bits default to **1** (bypassed) on reset — the design is
fully passive/passthrough until firmware explicitly enables decimation
and/or filtering.

---

## 5. Build Notes

- **Toolchain:** Vivado 2025.1.
- **Full build flow used during development:** from the Vivado GUI Tcl
  console (or `vivado -mode tcl`), `cd` into `projects/adrv9026/zcu102`
  and `source ./system_project.tcl`. The standard `make ORX_ENABLE=0`
  flow was not usable in this development environment (its `LIB_DEPS`
  step requires `flock`, unavailable under Git Bash/MSYS2 on Windows) —
  worth revisiting on a Linux build host.
- **IMPORTANT — IP repackaging:** `axi_adrv9026_rx_decimate_ctrl` is a
  packaged custom IP (`component.xml`), not a plain RTL reference. Any
  time `axi_cic_decimate_ctrl.v` / `axi_cic_decimate_ctrl_reg.v`'s **port
  list or parameter defaults** change (e.g. the `NUM_TAPS` correction in
  this revision), `component.xml` must be regenerated or Vivado will
  silently keep using the old values and either fail with a misleading
  "Illegal Name" error on `connect_bd_net`, or silently build with a
  stale parameter. Regenerate with:
  ```
  source /c/Xilinx/2025.1/Vivado/settings64.sh
  cd library/axi_cic_decimate_ctrl
  vivado -mode batch -source axi_cic_decimate_ctrl_ip.tcl
  ```
  Verify the change landed: `grep -A2 "NUM_TAPS" component.xml` should
  show the expected value.
- **`component.xml` is not tracked in git** (it's a generated build
  artifact, gitignored alongside `.jou`/`.log`/`.xpr`/`.cache` for this
  IP) — it's meant to regenerate automatically from
  `axi_cic_decimate_ctrl_ip.tcl` plus the tracked `.v` sources, normally
  via the project's standard `make`/`LIB_DEPS` flow. **On a Windows/Git
  Bash (MSYS2) build host, that automatic step fails** (`make xilinx`
  requires `flock`, which isn't available there) — see the note above
  this one for the manual `vivado -mode batch -source
  axi_cic_decimate_ctrl_ip.tcl` workaround. A teammate building on a
  normal Linux host should not need to do this manually; a teammate on
  Windows will hit the same `flock` failure and need the same
  workaround — worth flagging explicitly in any PR built from a Windows
  checkout.
- **Stale block-design cache:** `system_project.tcl` will reuse an
  existing `system.bd` / generated project directory if one is present,
  even after source Tcl edits. When in doubt, force a fully clean
  rebuild:
  ```
  rm -rf adrv9026_zcu102.srcs adrv9026_zcu102.gen adrv9026_zcu102.ip_user_files \
         adrv9026_zcu102.cache adrv9026_zcu102.hw adrv9026_zcu102.sim adrv9026_zcu102.xpr
  ```
- **Pasting Tcl console output:** copying directly out of the Vivado Tcl
  console into some external tools/chat clients can arrive corrupted or
  empty. If that happens, write results to a file from Tcl
  (`report_timing_summary -file <path>`, or `set fp [open <path> w];
  puts $fp <result>; close $fp` for `get_cells`/other query output) and
  read the file from a separate shell instead.
- **Verification checklist used throughout development** (Tcl console,
  after a build):
  ```tcl
  get_cells -hierarchical -filter {NAME =~ "*fir_compensator*"}
  get_cells -hierarchical -filter {NAME =~ "*fir_out_sat*"}
  get_cells -hierarchical -filter {NAME =~ "*coef_seq*"}
  get_cells -hierarchical -filter {NAME =~ "*chan_delay*"}
  get_cells -hierarchical -filter {NAME =~ "*axi_adrv9026_rx_decimate_ctrl*"}
  report_timing_summary
  check_timing -verbose
  ```
  Pass criteria: all `get_cells` return real synthesized logic (not
  empty — an early bug in this project involved Vivado silently
  optimizing away unconnected FIR logic), 0 `no_clock`, 0
  `unconstrained_internal_endpoints`, only the known board-level
  `no_input_delay`/`no_output_delay` items (SPI/sync pins), positive
  WNS, TNS = 0.000 **on paths touching this feature's logic** — see §6
  item 6 regarding a separate, pre-existing TX-domain timing issue that
  can show timing failures unrelated to this work.

---

## 6. Known Limitations / Open Items

1. **Channels 2–7 are not FIR-filtered.** They are decimated (if CIC is
   enabled) and latency-matched to channels 0/1, but receive no droop
   correction. Extending the FIR pair pattern to all 8 channels is the
   next planned step.
2. **`fir_enable_out_$i` is currently unused externally.** It exists as a
   hierarchy output pin but has no consumer in `adrv9026_bd.tcl` — the
   packer's per-channel `enable_$i` is driven directly from
   `rx_adrv9026_tpl_core`, not through the decimator.
3. **`fir_compiler`'s `s_axis_data_tready` is never connected** in the
   real design (only `tvalid`/`tdata` are wired). Likely benign in
   practice — the CIC's decimated output is naturally sparse relative to
   the FIR's consumption rate, so `tready` may never actually need to
   deassert — but this has not been formally verified against the
   real datapath's timing, only inferred. Worth a dedicated check.
4. **AXI4-Stream inputs left unconnected read as `X` in simulation** and
   can corrupt the FIR core's internal FIFO pointer logic (`"add_1 must
   be in range"` / `"empty_1 and not_empty_1 are inconsistent"` errors) —
   discovered while building the `fir_scale_check` testbench. Every input
   port on any `fir_compiler` instance must be explicitly tied to a
   defined value in any future testbench work against this core.
5. **Resource cost, for planning ahead:** one FIR-compensated channel
   pair costs 25 DSP48E2 (Symmetric structure). Extending to all 8
   real channels (item 1) would cost roughly 100 DSP48E2 total — well
   within budget on the xczu9eg (2520 available), based on current
   overall utilization (~12% LUTs, ~9% registers as of this revision).
6. **Pre-existing TX-domain timing fragility — unrelated to this
   feature, needs separate attention.** The `axi_adrv9026_tx_dma` /
   `adrv9026_data_offload` storage-and-forward path
   (`i_store_and_forward`/`i_dest_slice`/`fwd_data_reg`,
   `i_dest_dma_stream/active_reg` → data-offload RAM write/enable) has
   essentially zero designed-in timing margin — it was already only
   +0.050ns WNS in the very first pre-FIR baseline build of this
   project, and has swung between roughly +0.034ns and −0.031ns/
   −0.283ns TNS (0 to 20 failing endpoints) across multiple full clean
   rebuilds that made **no changes** to that part of the design,
   consistent with placement-seed sensitivity on a near-zero-margin
   path rather than anything caused by this RX CIC/FIR work. Device
   utilization was checked and rules out routing congestion as a cause
   (only ~12% LUTs used). **Recommend this be raised with whoever owns
   the TX DMA/data-offload block** — likely needs additional pipelining
   or a timing constraint refinement in that specific path.