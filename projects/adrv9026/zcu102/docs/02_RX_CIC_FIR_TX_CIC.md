# ADRV9026 RX/TX CIC Decimation/Interpolation + RX FIR Compensation

Adds programmable RX sample-rate decimation (5th-order CIC, rate 4–32),
programmable TX sample-rate interpolation (5th-order CIC, rate 4–32), and
47-tap (24 independent coefficients) FIR droop-compensation filtering to
the ADRV9026/ZCU102 HDL reference design.

**Status as of this document:**
- RX CIC decimation: implemented, working, all 8 real (I/Q) channels.
- RX FIR droop compensation: implemented, scale-corrected, verified
  end-to-end on **channels 0/1 only**. Channels 2–7 are decimated but not
  yet FIR-filtered.
- TX CIC interpolation: implemented and working, **channels 0/1 only**
  (`TX_CIC_ACTIVE_CHANNELS = 2`); channels 2–7 pass through unmodified
  when interpolation is enabled (constant zero) or in bypass (raw
  passthrough).
- TX FIR droop compensation (ahead of the interpolator): **not yet
  implemented** — planned next, same channel scope (0/1).

---

## 1. Architecture Overview

```
RX path (per real channel):
 adc_data_$i ──▶ CIC decimation (rate 4-32) ──▶ [bypass mux] ──▶ (ch 0/1
                                                                   only)
                                                 47-tap symmetric FIR
                                                 (droop correction) ──▶
                                                 24->16 saturate ──▶
                                                 [bypass mux] ──▶ packer/DMA
 (channels 2-7: CIC output delay-matched to the FIR pair's 35-cycle
  latency via fir_chan_delay, so the packer's single shared fifo_wr_en
  strobe stays valid across all 8 channels)

TX path (per real channel):
 fifo_rd_data_$i ──▶ [[TX FIR - NOT YET BUILT]] ──▶ CIC interpolation
                                                     (rate 4-32) ──▶
                                                     [bypass mux] ──▶
                                                     dac_data_$i

                     ┌─────────────────┐   ┌────────────────────┐
                     │ cic_cfg_seq.v   │   │ fir_coef_seq.v      │
                     │ (rate/reset,    │   │ (RX FIR coefficient │
                     │  shared by RX   │   │  reload sequencer)  │
                     │  dec + TX interp)│   └─────────┬───────────┘
                     └────────┬────────┘             │
                     ┌────────┴─────────────────────┴───────────┐
                     │   axi_adrv9026_cic_ctrl                    │
                     │   (AXI-lite register file, see §3)         │
                     └─────────────────────────────────────────────┘
```

### RX vs. TX bypass-mux placement (important for the TX FIR work ahead)

The RX decimator's bypass mux sits on the **output side**, gated by a
simple, always-present full-rate `valid` signal — the FIR after it just
processes whatever arrives.

The TX interpolator's bypass mux instead controls the **input pop-request
side**: `rden_mux` selects between the CIC core's own `s_axis_data_tready`
(interpolating — pop a new sample only once every R cycles) and
`full_rate_strobe` (bypass — pop every cycle, matching pre-interpolator
behavior), driving a single shared `fifo_rd_en` into
`util_adrv9026_tx_upack`. This is structurally different from the RX
side, and it means a TX FIR inserted ahead of the interpolator can't just
reuse the RX FIR's output-side bypass-mux pattern verbatim — see the
architecture note in the TX FIR design work (not yet finalized) for how
its own `tready`/pacing interacts with `rden_mux`.

### n_active_chan: resource-saving channel limiting (RX and TX)

Both `ad_add_cic_decimation_filter` and `ad_add_cic_interpolation_filter`
take an `n_active_chan` parameter: only the first `n_active_chan` of the
`n_chan` channels get real `cic_compiler` hardware. The remaining
channels have no CIC core at all — they output a constant zero whenever
decimation/interpolation is enabled, and pass raw data straight through
in bypass mode, same as every other channel. Currently:
`RX_CIC_ACTIVE_CHANNELS = 2`, `TX_CIC_ACTIVE_CHANNELS = 2` — i.e. real
CIC hardware exists only for the first complex channel (I0/Q0) on both
RX and TX.

### Why the RX FIR core's output is 24 bits internally, then saturated to 16

The FIR core's accumulator is 38 bits wide (sized for worst-case bit
growth, since `Coefficient_Reload = true`). The droop-correction
coefficients are Q1.14 fixed-point (14 fractional bits, needed because
the center tap exceeds 1.0). `Output_Width` is set to `24` (discarding
`38 − 24 = 14` bits, matching the coefficients' real scale) rather than
`16`, and a combinational module, `fir_out_sat.v`, truncates/saturates
that 24-bit value back to a clean 16-bit sample for the rest of the
datapath. Using `Output_Width = 16` directly would silently produce an
output ~256× too small — confirmed by simulation during development.

### Reset-timing fix (applies to both RX decimator and TX interpolator)

Both `cic_compiler` instances' `aresetn` are driven from a
`proc_sys_reset`-synchronized version of `cic_cfg_seq`'s
`cic_aresetn` output (`cic_rstgen` in each proc), not directly from
`cfg_seq/cic_aresetn`. Driving the CIC cores' `aresetn` directly from
`cic_aresetn` is an async reset whose value depends on a
data-carrying signal, which STA cannot verify recovery/removal timing
for. This fix was originally applied only to the decimator; when TX
interpolation was merged in, the interpolator was found to have the same
unfixed pattern and the identical fix was applied to it as part of that
merge.

---

## 2. Files

| File | Location | Purpose |
|---|---|---|
| `adi_cic_filter_bd.tcl` | `projects/common/xilinx/` | Block-design procs `ad_add_cic_decimation_filter` (RX) and `ad_add_cic_interpolation_filter` (TX) |
| `adrv9026_bd.tcl` | `projects/adrv9026/common/` | Top-level integration — instantiates `rx_cic_decimator`, `tx_cic_interpolator`, and `axi_adrv9026_cic_ctrl`, wires them to the ADC/DAC/packer/unpacker/DMA datapath |
| `cic_cfg_seq.v` | `projects/common/xilinx/` | Shared RX/TX rate/reset broadcast sequencer |
| `fir_coef_seq.v` | `projects/common/xilinx/` | RX FIR coefficient reload sequencer — streams `NUM_TAPS=24` taps over `S_AXIS_RELOAD`, then triggers `S_AXIS_CONFIG` |
| `fir_chan_delay.v` | `projects/common/xilinx/` | Dedicated 16-bit-wide N-cycle delay line, latency-matches RX channels 2–7 |
| `fir_out_sat.v` | `projects/common/xilinx/` | Combinational 24→16-bit saturating truncate for the RX FIR output |
| `util_delay.v` | `library/common/` | Pre-existing 1-bit delay utility, aligns the RX FIR's internal `enable` signal |
| `ad_bus_mux.v` | `library/common/` | Pre-existing combinational 2:1 mux — CIC/FIR bypass selection (RX) and `rden_mux` pop-request selection (TX) |
| `axi_cic_decimate_ctrl.v` | `library/axi_cic_decimate_ctrl/` | AXI-lite peripheral top-level (instantiated as `axi_adrv9026_cic_ctrl`) |
| `axi_cic_decimate_ctrl_reg.v` | `library/axi_cic_decimate_ctrl/` | Register file — see §3 |
| `axi_cic_decimate_ctrl_ip.tcl` | `library/axi_cic_decimate_ctrl/` | IP packaging script — **must be re-run any time ports/parameter defaults change** (see §5) |

---

## 3. Register Map

**Peripheral instance name:** `axi_adrv9026_cic_ctrl` (renamed from
`axi_adrv9026_rx_decimate_ctrl` when TX interpolation control was added —
same peripheral now serves RX decimation, TX interpolation, and RX FIR)
**HDL base address:** `0x44AB0000`
**Linux physical address (ZCU102):** `0x84AB0000`
**AXI address bus width:** 8 bits (byte address); word address is the
low 6 bits (`byte_addr >> 2`)

All registers are 32 bits wide. Byte offset = word address × 4.

| Word Addr | Byte Offset | Name | Access | Description |
|---|---|---|---|---|
| `0x00` | `0x00` | `VERSION` | RO | Peripheral version (`0x00010000`) |
| `0x01` | `0x04` | `SCRATCH` | RW | Scratch register, no function |
| `0x10` | `0x40` | `CIC_RATE` | RW | RX CIC decimation rate |
| `0x11` | `0x44` | `CIC_CONFIG` | RW/RO | RX CIC bypass + busy status |
| `0x12` | `0x48` | `TX_CIC_RATE` | RW | TX CIC interpolation rate |
| `0x13` | `0x4C` | `TX_CIC_CONFIG` | RW/RO | TX CIC bypass + busy status |
| `0x20` | `0x80` | `FIR_COEF_DATA` | WO | RX FIR: write one coefficient (auto-incrementing pointer) |
| `0x21` | `0x84` | `FIR_COEF_PTR_RST` | WO (strobe) | RX FIR: reset the coefficient write pointer to 0 |
| `0x22` | `0x88` | `FIR_LOAD` | WO (strobe) | RX FIR: trigger the reload sequencer |
| `0x23` | `0x8C` | `FIR_CONFIG` | RW/RO | RX FIR bypass + busy status |
| `0x24` | `0x90` | `FIR_COEF_COUNT` | RO | RX FIR: current coefficient write pointer |

**No existing addresses changed when TX interpolation was merged in** —
`0x12`/`0x13` were added in the gap between the RX and RX-FIR registers,
so nothing already documented for firmware moved.

**Open item:** TX FIR compensation (not yet built) will need its own
register block — likely continuing at `0x25`+, or a separate range —
to be finalized when that work starts.

### `CIC_RATE` (0x40) — RW
| Bits | Name | Description |
|---|---|---|
| `[7:0]` | `RATE` | RX decimation rate, valid range 4–32. Reset value: 4. |
| `[31:8]` | — | Reserved |

### `CIC_CONFIG` (0x44) — RW/RO
| Bits | Name | Access | Description |
|---|---|---|---|
| `[0]` | `BYPASS_ENABLE` | RW | 1 = raw ADC passthrough (no decimation). **Reset: 1**. 0 = decimation active. |
| `[1]` | `BUSY` | RO | 1 while RX CIC cores are resetting/reconfiguring after a rate change |
| `[31:2]` | — | Reserved |

### `TX_CIC_RATE` (0x48) — RW
| Bits | Name | Description |
|---|---|---|
| `[7:0]` | `RATE` | TX interpolation rate, valid range 4–32. Reset value: 4. |
| `[31:8]` | — | Reserved |

### `TX_CIC_CONFIG` (0x4C) — RW/RO
| Bits | Name | Access | Description |
|---|---|---|---|
| `[0]` | `BYPASS_ENABLE` | RW | 1 = raw DAC passthrough (no interpolation, pop every cycle). **Reset: 1**. 0 = interpolation active (pop paced by the CIC core's own tready). |
| `[1]` | `BUSY` | RO | 1 while TX CIC cores are resetting/reconfiguring after a rate change |
| `[31:2]` | — | Reserved |

### `FIR_COEF_DATA` (0x80) — WO
| Bits | Name | Description |
|---|---|---|
| `[15:0]` | `COEF` | Signed 16-bit coefficient (Q1.14 fixed-point). Written to the 24-entry array at the current pointer; pointer auto-increments. |
| `[31:16]` | — | Ignored on write |

Pointer saturates at `NUM_TAPS-1` (**23**) rather than wrapping.

### `FIR_COEF_PTR_RST` (0x84) — WO, strobe
Any write resets the coefficient pointer to 0. Must be written before
starting a fresh 24-word load — never implicitly reset any other way.

### `FIR_LOAD` (0x88) — WO, strobe
Any write triggers the RX FIR reload sequencer to stream the current
24-entry array to both FIR cores and issue the config-channel sync pulse.
Poll `FIR_CONFIG.BUSY` for completion.

### `FIR_CONFIG` (0x8C) — RW/RO
| Bits | Name | Access | Description |
|---|---|---|---|
| `[0]` | `BYPASS_ENABLE` | RW | 1 = raw CIC-output passthrough (FIR not in path). **Reset: 1**. |
| `[1]` | `BUSY` | RO | 1 while `fir_coef_seq` is streaming a reload |
| `[31:2]` | — | Reserved |

### `FIR_COEF_COUNT` (0x90) — RO
| Bits | Name | Description |
|---|---|---|
| `[5:0]` | `COUNT` | Current coefficient write pointer |
| `[31:6]` | — | Reserved |

Reading `23` (`0x17`) after a full load confirms all 24 words written.

---

## 4. Usage

### 4.1 Enabling RX CIC decimation
```
write CIC_RATE   = <4..32>
write CIC_CONFIG = 0x0
poll  CIC_CONFIG.BUSY until 0
```

### 4.2 Enabling TX CIC interpolation
```
write TX_CIC_RATE   = <4..32>
write TX_CIC_CONFIG = 0x0
poll  TX_CIC_CONFIG.BUSY until 0
```

### 4.3 Loading RX FIR coefficients (channels 0/1 only)
```
write FIR_COEF_PTR_RST = <any value>
repeat 24 times:
  write FIR_COEF_DATA = <next coefficient, signed 16-bit, Q1.14>
read  FIR_COEF_COUNT                       // expect 23 (0x17)
write FIR_LOAD = <any value>
poll  FIR_CONFIG.BUSY until 0
write FIR_CONFIG = 0x0
```

Coefficient order: write index `k` (`k = 0..23`) is coefficient `h[k]`
directly, confirmed via the generated core's `_reload_order.txt` — no
reordering needed. The mirrored second half (`h[24]..h[46]`) is never
written; the hardware reconstructs it from the symmetric structure.

The actual droop-correction coefficient set (Q1.14, write in order
`k = 0` to `23`):
```
k=0:  -133      k=6:   504      k=12: -1269     k=18:  3460
k=1:   173      k=7:  -707      k=13:  1822     k=19: -5444
k=2:  -233      k=8:   739      k=14: -1978     k=20:  6409
k=3:   159      k=9:  -537      k=15:  1541     k=21: -4759
k=4:    -3      k=10:   86      k=16:  -419     k=22: -3090
k=5:  -241      k=11:  560      k=17: -1332     k=23: 25584  (center tap)
```
Written exactly as-is via `FIR_COEF_DATA` — no firmware-side rescaling
needed. FIR core reset only fires once, at power-up (independent of the
RX CIC's rate-change reset); firmware must perform a full coefficient
load after every power-up before the FIR produces correct output.

### 4.4 Bypass control summary
| Register | Bit | Effect when set to 1 |
|---|---|---|
| `CIC_CONFIG` | `BYPASS_ENABLE` | Raw ADC data through, no decimation, all 8 RX channels |
| `TX_CIC_CONFIG` | `BYPASS_ENABLE` | Raw DAC data through, no interpolation, all 8 TX channels |
| `FIR_CONFIG` | `BYPASS_ENABLE` | CIC output through unfiltered, RX channels 0/1 only |

All three bypass bits default to **1** on reset — fully passive until
firmware explicitly enables each stage.

---

## 5. Build Notes

- **Toolchain:** Vivado 2025.1.
- **Full build flow:** from the Vivado GUI Tcl console (or `vivado -mode
  tcl`), `cd` into `projects/adrv9026/zcu102` and `source
  ./system_project.tcl`. `make ORX_ENABLE=0` is not usable in this
  development environment (`LIB_DEPS` requires `flock`, unavailable
  under Git Bash/MSYS2 on Windows).
- **IP repackaging required after any port/parameter change:**
  ```
  source /c/Xilinx/2025.1/Vivado/settings64.sh
  cd library/axi_cic_decimate_ctrl
  vivado -mode batch -source axi_cic_decimate_ctrl_ip.tcl
  ```
  Verify with `grep -n "<port_name>" component.xml`.
- **`component.xml` is not tracked in git** — regenerable from
  `axi_cic_decimate_ctrl_ip.tcl` plus the tracked `.v` sources, normally
  via `make`'s `LIB_DEPS` step. That step fails under Git Bash/MSYS2
  (needs `flock`); use the manual repackaging command above instead on
  Windows.
- **Stale block-design cache:** force a fully clean rebuild when in
  doubt:
  ```
  rm -rf adrv9026_zcu102.srcs adrv9026_zcu102.gen adrv9026_zcu102.ip_user_files \
         adrv9026_zcu102.cache adrv9026_zcu102.hw adrv9026_zcu102.sim adrv9026_zcu102.xpr
  ```
- **KNOWN ISSUE — `system_project.tcl`'s automated flow can hang** at
  its post-implementation `report_timing_summary`/`write_hw_platform`
  step, even after `write_bitstream` itself completes successfully
  (confirmed via a fresh `.bit` timestamp). Root cause not identified.
  **Working manual workaround**, run directly against the existing
  implemented design once `write_bitstream Complete` is confirmed:
  ```tcl
  open_project C:/ADI/hdl/projects/adrv9026/zcu102/adrv9026_zcu102.xpr
  open_run impl_1
  report_timing_summary -file "C:/ADI/hdl/timing_summary_manual.txt"
  write_hw_platform -fixed -force -include_bit -file C:/ADI/hdl/projects/adrv9026/zcu102/adrv9026_zcu102.sdk/system_top.xsa
  ```
  Confirm timing actually passes (WNS ≥ 0, TNS = 0.000) in the manual
  report *before* trusting the `.xsa` — this bypasses the automated
  script's own pass/fail gate, so that check has to be done by hand.
- **Verification checklist** (Tcl console, after a build) — use
  `llength` rather than printing full cell lists, which can be
  unmanageably long for larger hierarchies like the interpolator:
  ```tcl
  puts "fir_compensator: [llength [get_cells -hierarchical -filter {NAME =~ "*fir_compensator*"}]]"
  puts "fir_out_sat: [llength [get_cells -hierarchical -filter {NAME =~ "*fir_out_sat*"}]]"
  puts "coef_seq: [llength [get_cells -hierarchical -filter {NAME =~ "*coef_seq*"}]]"
  puts "chan_delay: [llength [get_cells -hierarchical -filter {NAME =~ "*chan_delay*"}]]"
  puts "axi_adrv9026_cic_ctrl: [llength [get_cells -hierarchical -filter {NAME =~ "*axi_adrv9026_cic_ctrl*"}]]"
  puts "cic_interpolator: [llength [get_cells -hierarchical -filter {NAME =~ "*cic_interpolator*"}]]"
  ```
  All should be well above 0. Pass criteria for timing: WNS ≥ 0, TNS =
  0.000, 0 failing endpoints on paths touching this feature's logic
  (see §6 item 6 regarding a separate pre-existing TX DMA timing issue).

---

## 6. Known Limitations / Open Items

1. **RX channels 2–7 are not FIR-filtered** — decimated and
   latency-matched to channels 0/1, no droop correction.
2. **TX FIR compensation (ahead of the interpolator) is not yet
   implemented** — planned next, channels 0/1 only. Architecturally
   different from the RX FIR pattern: the interpolator's bypass mux
   controls the *input pop-request* side (`rden_mux`/`fifo_rd_en`), not
   the output side, so the RX output-side bypass-mux approach doesn't
   directly transplant; the TX FIR's own `tready`/pacing behavior needs
   to be reasoned about relative to `rden_mux` before implementation.
3. **TX channels 2–7** get no interpolation (constant zero when enabled,
   same `n_active_chan` convention as RX).
4. **`fir_enable_out_$i` (RX) is unused externally** — the packer's
   per-channel `enable_$i` comes directly from `rx_adrv9026_tpl_core`.
5. **`fir_compiler`'s `s_axis_data_tready` (RX) is never connected** —
   likely benign given the CIC's naturally sparse decimated output, but
   not formally verified.
6. **Pre-existing TX-domain timing fragility, unrelated to this feature**
   — the `axi_adrv9026_tx_dma`/`adrv9026_data_offload` storage-and-forward
   path has essentially zero designed-in timing margin (already only
   +0.050ns WNS in the very first pre-FIR baseline). Device utilization
   rules out routing congestion as a cause. `system_project.tcl`'s
   implementation strategy changed (`Performance_RefinePlacement` →
   `Performance_ExplorePostRoutePhysOpt`, targets post-route physical
   optimization) as part of the interpolator merge — plausibly relevant
   to this path's margin, not yet confirmed causally. Two builds of the
   merged design so far: WNS +0.010ns and +0.003ns, both 0 failing
   endpoints — an encouraging early trend, but the sample size is still
   small given this path's history of swinging between builds.
   Recommend raising with whoever owns the TX DMA/data-offload block.
7. **Resource cost:** one RX FIR-compensated channel pair costs 25
   DSP48E2 (Symmetric structure). Extending to all 8 RX channels would
   cost roughly 100 DSP48E2 — well within budget on the xczu9eg (2520
   available).