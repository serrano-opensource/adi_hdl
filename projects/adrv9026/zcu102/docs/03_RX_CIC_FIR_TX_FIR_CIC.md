# ADRV9026 RX CIC + FIR / TX FIR + CIC (Decimation, Interpolation, Droop Compensation)

**Milestone 03.** Adds a TX FIR compensation filter ahead of the TX CIC
interpolator (channels 0/1), makes both FIRs power up as unity filters, and
fixes a CIC rate-change bug found while verifying the TX FIR. Builds on
`01_RX_CIC_FIR.md` (RX CIC + RX FIR) and `02_RX_CIC_FIR_TX_CIC.md` (adds the
TX CIC interpolator).

**Naming.** The filename lists the filters in signal-flow order for each
direction: RX is CIC then FIR (`RX_CIC_FIR`), TX is FIR then CIC
(`TX_FIR_CIC`), because the TX FIR sits *ahead of* the interpolator.

**Status of the claims in this document.** Everything below is marked as
verified in simulation, verified in a build, or not yet verified on hardware
(section 5). Nothing in this milestone has been run on hardware yet.

**Build status (TX FIR, branch `wweeks/cic-tx-fir`).** A clean rebuild from the
sources with `Performance_Explore` (source checksum
`daf2c3e6a5921053f98e8d47a411930a`) met timing: WNS +0.041 ns, TNS 0, WHS
+0.0099 ns, 0 `no_clock`, 0 unconstrained internal endpoints, RX 25 / TX 7
DSP48E2 per FIR channel, and the flow wrote `system_top.xsa` (not
`_bad_timing`). It is a single build. A second identical build was not run,
and earlier builds of the same sources with other strategies failed by up to
52 ps, so the pass belongs to that `.xsa`, not to the commit: rebuilding from
the commit may land on either side of zero. This is the build FW has for
testing.

**Build status (gain-compensation fix, branch `wweeks/cic-gain-compensation`,
based on the same commit FW is testing).** Section 1.5 adds a per-rate
gain-compensation stage that corrects the non-power-of-two output-level bug in
limitation 2 below. Two clean rebuilds from identical sources (checksum
`e5b810c347cc3410ef1408d946041882`) both met timing: WNS +0.0074 ns and
+0.0176 ns, TNS 0 on both, WHS +0.0101 ns and +0.0099 ns, `check_timing` clean
on both (0 `no_clock`, 0 unconstrained endpoints, the same 3/4 board-level
ports as every prior build). DSP48E2: RX 25 / TX 7 per FIR channel (unchanged)
plus 1 per `cic_gain_comp` instance (RX 0/1, TX 0/1 — 4 total, new). `.xsa`
md5sums `57cf16863cf5acc71636e280aa3ef0b4` (build gc-1) and
`c566d014d3afca427e7954133f34a84d` (build gc-2). Neither build carries a
distinct `VERSION` value — both still read `0x00010100`, identical to the TX
FIR build FW already has, so there was no register-level way to confirm the
fix's presence on hardware.

**Build status (VERSION bump, same branch, source checksum
`364413ca33d99066f3f235fe2e9b1267`).** `VERSION` bumped to **`0x00010101`**
(`library/axi_cic_decimate_ctrl/axi_cic_decimate_ctrl_reg.v`, `up_version`)
specifically so this fix is distinguishable from `0x00010100` on hardware. A
third clean build (gc-3) on the bumped sources met timing: WNS +0.0083 ns, TNS
0, WHS +0.0092 ns; DSP48E2 unchanged (RX 25 / TX 7 per FIR channel, 1 per
`cic_gain_comp`). The version constant is optimized out of the netlist (no
dynamic writes to it), so it could not be confirmed by inspecting the
implemented design directly — confirmed instead at the source level (the
checksum above covers the edit) and by the read-case wiring
(`up_rdata <= up_version` at address `0x00`), the same mechanism that already
correctly carried `0x00010000` -> `0x00010100`. **This is the build going to
FW.** `.xsa`: `adrv9026_zcu102.sdk/system_top.xsa`, md5 `388886a757592c63349a663faa1490c4`.
Get FW to confirm `VERSION` reads `0x00010101` (`devmem 0x84AB0000 32`) as
their first bring-up step — this is the actual proof the fix is in the
bitstream they're running, not just something intended in the source. This
branch is **not yet merged into `wweeks/cic-tx-fir`**.

## What changed for firmware (read this first)

1. **New TX FIR register block** at byte offsets `0xC0`-`0xD0` (section 3),
   mirroring the RX FIR block at `0x80`-`0x90`. The TX FIR **resets to bypass
   (1)**, like every other bypass bit.
2. **RX and TX FIR coefficient sets are stored and loaded independently.**
   Today both use the same 24-value droop-correction table (see `02_` section
   4.3; confirmed identical by the FW team), but firmware must **write and load
   each block separately** (RX at `0x80`-`0x88`, TX at `0xC0`-`0xC8`). Loading the
   RX block does not populate the TX block. The split exists so the two sets can
   diverge later with no FPGA change.
3. **Both FIRs power up as unity filters.** The coefficient memories (RX and TX)
   and the FIR cores are seeded with a center tap of `16384` (1.0 in Q1.14) and
   zeros elsewhere, so a `FIR_LOAD` issued before any coefficient writes passes
   data unchanged instead of loading an all-zero filter. The RX core's seed used
   to be a center tap of `1` (near-zero gain); it now matches TX. Whether the
   bitstream honors the memory initial values is confirmed only in simulation.
4. **CIC rate changes were being erased (RX and TX) and are fixed.** See
   section 1.4. After writing `CIC_RATE` / `TX_CIC_RATE`, `BUSY` now stays high
   for about **60 cycles** (58 measured in simulation) instead of a handful.
   Wait for `BUSY` to clear before assuming the new rate is active.
5. **TX FIR loads need samples flowing.** The FIR core only completes a
   coefficient reload while samples are being pushed into it (section 1.2). With
   the TX path running, `TX_FIR_CONFIG.BUSY` clears about 21 cycles after
   `TX_FIR_LOAD`. Loading with no TX samples flowing (for example with the JESD
   TX link down) may leave `BUSY` high until samples start; this is inferred from
   simulation, not observed on hardware.
6. **The version register at `0x00` distinguishes which fixes a build has.**
   `0x00010100` (was `0x00010000`) = TX FIR + rate-change fix. **`0x00010101`
   = the same, plus the CIC gain-compensation fix (section 1.5)** that
   corrects the non-power-of-two output-level bug — check this value first if
   you're not sure which build you're running. Read as major.minor.patch in
   ADI's usual layout (`[31:16]`, `[15:8]`, `[7:0]`); this core's docs do not
   define the fields, so treat it as a "which fixes are present" marker, not
   a formal semantic version.

## 1. Architecture Overview

### 1.1 TX datapath (channels 0/1 only)

```
util_adrv9026_tx_upack --fifo_rd_data_$i--> FIR --> 24->16 saturate --> hold register --> [fir_in_mux] --> CIC --> out_mux --> TPL
                                                                                              ^                        ^
                                                                          raw data_in_$i -----+--- (bypass path) ------+
```

- `fir_in_mux` select = `TX_FIR_CONFIG.BYPASS_ENABLE`. 1 = the CIC is fed the
  raw upacker data (FIR skipped); 0 = the CIC is fed the FIR output.
- The raw `data_in_$i` -> `out_mux` path used by `TX_CIC_CONFIG.BYPASS_ENABLE`
  is unchanged. **If TX CIC bypass is set, the FIR is out of the path
  regardless of `TX_FIR_CONFIG`.**
- Channels 2-7 are unchanged from milestone 02 (constant zero when
  interpolating, raw passthrough in CIC bypass). Only converter indices 0/1
  (the I/Q pair of complex channel 0, `TX_CIC_ACTIVE_CHANNELS = 2`) get a FIR.

### 1.2 Why the TX FIR differs from the RX FIR

- **Pop pacing is unchanged.** The interpolator requests samples from the
  upacker through `rden_mux` / the shared `fifo_rd_en`, paced by channel 0's CIC
  `s_axis_data_tready` (one pop per R cycles once the rate is applied, R >= 4).
  The FIR sits on the data wires only and does not touch pop timing.
- **Hold register.** The upacker's `fifo_rd_data` is registered and holds
  between pops, and the CIC samples only on its own `tready`. A hold register
  after the FIR output keeps the CIC's input stable regardless of the FIR's
  latency, so samples are neither dropped nor duplicated.
- **Folded core.** Because pops arrive at most once per 4 cycles, the FIR is
  generated with `SamplePeriod = 4` (Symmetric, 24 independent coefficients,
  47 taps) and uses **7 DSP48E2 per channel** (the RX FIR uses 25).
- **Input valid** = `fifo_rd_valid | fifo_rd_underflow`. On an upacker
  underflow, zeros flow through the FIR instead of being skipped. The input is
  **deliberately not gated by bypass**: the FIR core only completes a
  coefficient reload while samples flow into it. In simulation, a second load
  with no samples since the first stalled (`BUSY` stuck) until data arrived, and
  gating the input with the CIC bypass bit produced exactly that stall (an
  earlier version of this design had that gate). In CIC bypass, full-rate pops
  overflow the FIR's input FIFO and samples are dropped; the FIR output is
  unused there, so this is harmless to the data path.
- **Reload order.** The folded core wants its 24 reload beats sent as
  `h[20..23], h[16..19], h[12..15], h[8..11], h[4..7], h[0..3]` (`h[23]` is the
  center tap). `fir_coef_seq` has a `FOLD_LOG2` parameter (TX = 2, RX = 0) that
  remaps the beat order in hardware. The register file stays in natural order.
- **Reset.** The TX FIR has its own reset (`fir_rstgen`), generated once at
  power-up and never touched by a rate change or a coefficient load. Same rule
  as RX (a reset after a config packet can leave `s_axis_reload_tready` stuck;
  in simulation a reset followed by a load with no samples in between also
  stalled).

### 1.3 Numbers (standalone core and hierarchy simulation)

| Item | Value |
|---|---|
| Core pipeline latency | 24 clock cycles (RX FIR: 35) |
| Output rate | 1 sample per 4 cycles at the fastest interpolation rate |
| Coefficients per load | 24 beats, `tlast` on the last, then one config beat |
| Unity check | center tap `16384`, DC in = DC out exactly |
| Load time | `BUSY` clears 21 cycles after `FIR_LOAD` with samples flowing |

**End-to-end delay of the FIR path** (interpolator hierarchy simulation, unity
FIR vs. the FIR-bypassed path, channels 0/1; the FIR path output equals the
bypassed-path output delayed by a whole number of input samples at every rate):

| Interpolation rate R | 32 | 16 | 8 | 5 | 4 |
|---|---|---|---|---|---|
| Added delay (input samples) | 23 | 24 | 26 | 28 | 29 |
| Added delay (clock cycles) | 736 | 384 | 208 | 140 | 116 |

The 23 samples are the filter's own group delay; the rest is the core pipeline
plus the hold register. The R=4 figure is for entry through a rate change; see
limitation 3 for entry straight from CIC bypass.

### 1.4 CIC rate-change fix (RX and TX)

**Symptom (simulation of the merged design, before the fix).** With TX
interpolation enabled, writing a rate other than 4 had no lasting effect: the
interpolator kept requesting one sample every 4 cycles. The bare `cic_compiler`
core at the same settings follows every rate tested (4, 5, 8, 16, 32), so the
core is not at fault.

**Cause.** `cic_cfg_seq` pulses `cic_aresetn` low, releases it, and sends the
new rate on the config channel. The block design routes `cic_aresetn` through
a `proc_sys_reset` (`cic_rstgen`) before it reaches the CIC cores, and that block
delays and stretches the pulse. In the trace, the config beat was accepted 5
cycles before the core's own reset asserted; the reset then erased it (the core
returned to its power-up rate of 4) and stayed asserted for about 47 cycles. The
sequencer had already gone idle, so nothing resent the rate. `BUSY` cleared a
handful of cycles after the write, so software saw a normal completion.

**Fix.** `cic_cfg_seq` gains a `core_aresetn` input (wired from
`cic_rstgen/peripheral_aresetn`) and a new `ST_WAIT` state. After the reset
pulse the sequencer waits until it has seen the core's reset assert **and**
release, and only then sends the config. `WAIT_CYCLES` (default 256) bounds the
wait so an unconnected `core_aresetn` cannot deadlock it. The connection is added
to both the decimation and interpolation procs in `adi_cic_filter_bd.tcl`.

**Evidence.** In the TX interpolator hierarchy simulation, with the fixed
sequencer, R=32 gave 62 pops in 2000 cycles and R=8 gave 250 (the expected
values); before the fix both gave 500 (the rate-4 cadence).

**RX.** The RX decimator uses the same module and the same `cic_rstgen`
arrangement (since commit `e3a737f4a`), and shows the same behavior in
simulation of the exported RX hierarchy: with the committed sequencer the
decimator produced 1000 output pulses per 4000 cycles at every rate (the R=4
cadence; expected 125, 250, 500, 800 at R = 32, 16, 8, 5), with `busy` clearing 5
cycles after each change. With the fixed sequencer it produced 125, 250, 500,
800 and 1000, with `busy` high about 58 cycles after each change.

**What is not verified.** Hardware behavior, before or after the fix, has not
been observed. The builds validated by FW before this milestone are expected to
have the old behavior in both directions.

### 1.5 CIC gain-compensation fix (RX and TX)

**Symptom.** FW reported output levels dropping several dB whenever the CIC
rate is not a power of two. Confirmed by a full R = 4..32 sweep of the bare
`cic_compiler` core (DC input, both directions): flat at every power-of-two
rate, up to -5.92 dB (TX, worst at R = 27) and -5.80 dB (RX, worst at R = 7,
14, 28) elsewhere.

**Cause.** Reconfiguring the CIC IP for `Quantization = Full_Precision`
(needed so no bits are lost before compensation) revealed the real mechanism.
A direct calibration sweep against the `Full_Precision` core (raw output, no
shift, no gain) showed the output is the exact, fully unshifted product:
`raw = input * R**EXP` (`EXP = 4` for the TX interpolator, `EXP = 5` for the RX
decimator) — for example TX R = 5: `625000 = 1000 * 5**4`, exactly, at every
rate checked. The bare core's normal (non-`Full_Precision`) output is that
same raw value right-shifted by a single **fixed** amount sized for the
worst-case rate (R = 32); at every other rate the shift throws away more than
it should, and the shortfall is the attenuation.

**Fix.** Two new files, `projects/common/xilinx/cic_gain_lut.v` and
`cic_gain_comp.v`, inserted between each CIC core's (now `Full_Precision`)
output and the rest of the datapath (RX: ahead of the RX FIR and the
bypass mux; TX: the hierarchy's final output stage, since the TX FIR sits
ahead of the CIC on that side):

- `cic_gain_lut` is a lookup table, indexed by rate (4..32), giving two values
  per rate: a per-rate right-shift amount (`shift`, the same shift the old
  truncating core used — reproduces its raw output exactly) and a Q1.14
  reciprocal gain (`gain`) that restores that shifted value to the level R = 32
  already has. Both are pure functions of `R**EXP`, computed once in Python and
  hardcoded as two `case` statements (`EXP = 4` instantiated for TX, `EXP = 5`
  for RX — same module, one parameter).
- `cic_gain_comp` applies them: `raw >>> shift`, then multiply by `gain`
  (Q1.14), round to nearest, saturate to 16 bits. Three pipeline stages.
- Both are fed from a **new `active_rate` output on `cic_cfg_seq`**, not the
  raw `rate` input pin: `active_rate` only updates once the rate-change
  sequencer has confirmed the CIC core accepted the new rate (the same
  `cfg_tready` handshake the 1.4 fix already uses), so the gain and shift never
  run ahead of the core during a rate change. This closes a real bug caught
  before it was ever built: tying the LUT to the raw `rate` pin would have
  applied the *new* rate's compensation for the ~60 cycles the core is still
  finishing the *old* rate.
- On TX, `gain_comp`'s `din_valid` ties to `VCC` (the CIC input is already
  free-running there) and `dout_valid` is left unconnected, matching the
  existing convention that this datapath has no real valid signal (the JESD TX
  transport has no valid input). On RX, `din_valid`/`dout_valid` carry the
  CIC core's real `m_axis_data_tvalid` through to the downstream mux.

**Two bugs found and fixed during this work, both in `cic_gain_comp.v` before
the design was ever built:**
1. **Missing shift stage.** The first version multiplied the *raw*, unshifted
   `Full_Precision` output directly by the Q1.14 gain, which just saturated at
   max positive at every rate (confirmed in a real-hierarchy simulation before
   the fix). The shift above was the missing piece.
2. **`PROD_WIDTH` undersized by 2 bits.** An `(N+1)`-bit signed times a 17-bit
   signed product needs `N+18` bits to represent exactly; the first version
   declared `N+16`. Harmless before the shift fix (the raw operand was so wide
   the shortfall never bit), but fixed properly once the shift narrowed the
   operand down to a size where it would have mattered.

**A third issue surfaced only in the full project build**, not in any
standalone simulation: `cic_gain_comp.v`'s ports were originally named
`din`/`dout`. The full `adrv9026_zcu102` project loads the entire ADI library
as an IP repository, which defines a custom bus interface
(`analog.com:interface:fifo_rd`) that Vivado's IP packager auto-infers from
ports literally named `din`/`dout` — silently turning them into interface
pins that then cannot connect to an ordinary pin (`ad_connect: Cannot connect
non-interface to interface`). No scratch/elaboration test ever loaded that
same IP repository, so nothing caught this until the real build. Fixed by
renaming to `gain_din`/`gain_dout` (`din_valid`/`dout_valid` unaffected).

**Verification (real modified hierarchy in simulation, not the bare core; DC
input 1000, relative to R = 4):**

| R | RX dB | TX dB | R | RX dB | TX dB | R | RX dB | TX dB |
|---|---|---|---|---|---|---|---|---|
| 4 | 0.00 | 0.00 | 14 | -0.02 | 0.00 | 24 | 0.00 | -0.01 |
| 5 | -0.01 | -0.01 | 15 | 0.00 | -0.01 | 25 | 0.00 | 0.00 |
| 6 | 0.00 | -0.01 | 16 | 0.00 | 0.00 | 26 | 0.00 | -0.01 |
| 7 | -0.02 | 0.00 | 17 | 0.00 | 0.00 | 27 | 0.00 | -0.02 |
| 8 | 0.00 | 0.00 | 18 | 0.00 | -0.01 | 28 | -0.02 | 0.00 |
| 9 | 0.00 | -0.01 | 19 | -0.01 | 0.00 | 29 | 0.00 | -0.01 |
| 10 | -0.01 | -0.01 | 20 | -0.01 | -0.01 | 30 | 0.00 | -0.01 |
| 11 | -0.01 | -0.01 | 21 | -0.01 | -0.01 | 31 | 0.00 | -0.01 |
| 12 | 0.00 | -0.01 | 22 | -0.01 | -0.01 | 32 | 0.00 | 0.00 |
| 13 | 0.00 | -0.01 | 23 | 0.00 | -0.01 | | | |

Flat within +/-0.02 dB at every rate on both sides (worst case R = 27, both
directions) versus -5.92 dB (TX) / -5.80 dB (RX) before the fix. The residual
+/-0.01/0.02 dB is Q1.14 gain rounding, not a rate-dependent trend.

**Resource cost.** 1 DSP48E2 per `cic_gain_comp` instance (RX 0/1, TX 0/1 — 4
total), confirmed on both clean builds; a plain barrel shifter otherwise
(no DSP). Negligible next to the 25 (RX) / 7 (TX) DSP48E2 already used per FIR
channel.

**Not yet done:** merging this branch into `wweeks/cic-tx-fir`, updating the
FW programming guide, and hardware verification (VERSION readback is the
first step FW should take — see the build-status note above).

## 2. Files

| File | Change |
|---|---|
| `projects/common/xilinx/cic_cfg_seq.v` | new `core_aresetn` input and `ST_WAIT` state (rate-change fix, RX and TX) |
| `projects/common/xilinx/adi_cic_filter_bd.tcl` | `ad_add_cic_interpolation_filter`: FIR, saturator, hold register, input mux, `fir_coef_seq`, new pins. Both procs: `core_aresetn` wiring. Decimation proc: RX FIR seed center tap 1 -> 16384 |
| `projects/adrv9026/common/adrv9026_bd.tcl` | wires `fifo_rd_valid`/`fifo_rd_underflow` from the TX upacker and the five `tx_fir_*` control signals |
| `projects/common/xilinx/fir_out_hold.v` | **new**: hold register |
| `projects/common/xilinx/fir_coef_seq.v` | new `FOLD_LOG2` parameter (default 0 = unchanged behavior) |
| `library/axi_cic_decimate_ctrl/axi_cic_decimate_ctrl_reg.v` | TX FIR register block, TX coefficient memory, CDC, unity power-up contents for both memories, version bump |
| `library/axi_cic_decimate_ctrl/axi_cic_decimate_ctrl.v` | exposes the five `tx_fir_*` ports |

`fir_out_sat.v` is reused from RX unchanged. `projects/adrv9026/zcu102/system_project.tcl`
changes only the implementation strategy line (section 5); it now sets
`Performance_Explore`.

**Gain-compensation fix (branch `wweeks/cic-gain-compensation`, section 1.5;
not yet merged into the branch above):**

| File | Change |
|---|---|
| `projects/common/xilinx/cic_gain_lut.v` | **new**: per-rate shift + Q1.14 gain lookup |
| `projects/common/xilinx/cic_gain_comp.v` | **new**: shift, multiply, round, saturate stage |
| `projects/common/xilinx/cic_cfg_seq.v` | new `active_rate` output, latched once the core accepts a rate change |
| `projects/common/xilinx/adi_cic_filter_bd.tcl` | both procs: `Quantization` -> `Full_Precision`, `cic_gain_lut`/`cic_gain_comp` instances and wiring |

## 3. Register Map (additions)

Byte offsets (word address x 4), in the AXI-Lite space of
`axi_adrv9026_cic_ctrl`. The TX FIR logic is clocked by the TX device clock; the
crossings mirror the RX FIR ones.

| Offset | Name | Access |
|---|---|---|
| `0xC0` | `TX_FIR_COEF_DATA` | WO |
| `0xC4` | `TX_FIR_COEF_PTR_RST` | WO, strobe |
| `0xC8` | `TX_FIR_LOAD` | WO, strobe |
| `0xCC` | `TX_FIR_CONFIG` | RW/RO |
| `0xD0` | `TX_FIR_COEF_COUNT` | RO |

**Changed register.** `VERSION` (`0x00`, RO) reads `0x00010100` on the TX FIR
build (`wweeks/cic-tx-fir`, was `0x00010000`) and **`0x00010101`** on this
gain-compensation build (`wweeks/cic-gain-compensation`, section 1.5) — the
patch field distinguishes "TX FIR + rate-change fix" from "TX FIR +
rate-change fix + gain compensation". In ADI's usual layout (`[31:16]` major,
`[15:8]` minor, `[7:0]` patch) `0x00010101` is 1.1.1; this core's docs do not
define the fields, so treat it as a marker of which fixes are present rather
than a formal semantic version. Existing register addresses are unchanged (the
CIC `BUSY` bits stay high longer after a rate
write, see 1.4).

### `TX_FIR_COEF_DATA` (0xC0) — WO
| Bits | Name | Description |
|---|---|---|
| `[15:0]` | `COEF` | Signed 16-bit coefficient (Q1.14). Written to the 24-entry array at the current pointer; pointer auto-increments. |
| `[31:16]` | — | Ignored on write |

The pointer saturates at 23 rather than wrapping. The array powers up as a unity
filter (`[23] = 16384`, others 0).

### `TX_FIR_COEF_PTR_RST` (0xC4) — WO, strobe
Any write resets the coefficient pointer to 0. Write it before every fresh
24-word load.

### `TX_FIR_LOAD` (0xC8) — WO, strobe
Any write starts the TX reload sequencer: it streams the 24-entry array to both
TX FIR cores (in the folded order, remapped in hardware) and issues the config
beat. Poll `TX_FIR_CONFIG.BUSY` for completion. Completion needs samples flowing
into the FIR (section 1.2).

### `TX_FIR_CONFIG` (0xCC) — RW/RO
| Bits | Name | Access | Description |
|---|---|---|---|
| `[0]` | `BYPASS_ENABLE` | RW | 1 = FIR out of the path (CIC fed raw data). **Reset: 1**. |
| `[1]` | `BUSY` | RO | 1 while the TX sequencer is streaming a reload |
| `[31:2]` | — | Reserved |

### `TX_FIR_COEF_COUNT` (0xD0) — RO
| Bits | Name | Description |
|---|---|---|
| `[5:0]` | `COUNT` | Current coefficient write pointer |
| `[31:6]` | — | Reserved |

Reading `23` (`0x17`) after a full load confirms all 24 words were written.

## 4. Usage

### 4.1 Loading TX FIR coefficients (channels 0/1 only)
```
write TX_FIR_COEF_PTR_RST = <any value>
repeat 24 times:
  write TX_FIR_COEF_DATA = <next coefficient h[k], k = 0..23, signed 16-bit, Q1.14>
read  TX_FIR_COEF_COUNT                       // expect 23 (0x17)
write TX_FIR_LOAD = <any value>
poll  TX_FIR_CONFIG.BUSY until 0
write TX_FIR_CONFIG = 0x0                      // FIR into the path
```

`h[0]` is the outermost tap and `h[23]` is the center tap; the other 23 taps
are mirrored by the symmetric structure. Write the coefficients in this natural
order; the hardware performs the reordering the folded core needs.

Use the same 24-value table as RX (`02_`, section 4.3) unless the sets are
deliberately changed. This load is **separate** from the RX load (section 4.1 of
`01_`/`02_`): do both. As with RX, the FIR is reset only at power-up, so
firmware must do a full coefficient load after every power-up before relying on
the filter.

### 4.2 Path check without designing coefficients
- **Power-up unity filter:** with TX interpolation enabled, clear
  `TX_FIR_CONFIG.BYPASS_ENABLE` without loading anything. The FIR core's seed is
  a unity filter, so the output should equal the same signal with the FIR
  bypassed, apart from a small fixed delay. This also checks the seed.
- **Explicit unity load:** write `h[0..22] = 0`, `h[23] = 16384`, load, and clear
  bypass. In the standalone simulation this passes DC unchanged (1000 in, 1000
  out). This checks the load path, the reorder, and the scaling.

### 4.3 Changing the interpolation or decimation rate
Write `TX_CIC_RATE` / `CIC_RATE`, then poll the matching `BUSY` bit until it
clears (about 60 cycles). Before the sequencer fix in section 1.4, a rate other
than 4 did not take effect in simulation.

### 4.4 Bypass control summary
| Register | Bit | Effect when set to 1 |
|---|---|---|
| `CIC_CONFIG` | `BYPASS_ENABLE` | Raw ADC data through, no decimation, all 8 RX channels |
| `TX_CIC_CONFIG` | `BYPASS_ENABLE` | Raw DAC data through, no interpolation, all 8 TX channels (**also removes the TX FIR from the path**) |
| `FIR_CONFIG` | `BYPASS_ENABLE` | RX: CIC output through unfiltered, channels 0/1 only |
| `TX_FIR_CONFIG` | `BYPASS_ENABLE` | TX: CIC fed unfiltered data, channels 0/1 only |

All four bypass bits default to **1** on reset.

## 5. Build Notes and Verification

- Build procedure is unchanged from `02_` (clean rebuild via
  `system_project.tcl`). Because `axi_cic_decimate_ctrl` gained ports and
  registers, the IP must be **repackaged first** from a Vivado Tcl shell (`cd`
  into `library/axi_cic_decimate_ctrl`, then `source
  axi_cic_decimate_ctrl_ip.tcl`); `make` does not work in this environment.
  Check `component.xml` for the `tx_fir_` ports before starting the project
  build.

**Last build that met timing** (TX FIR registers and sequencer, with the bypass gate,
zero-initialized coefficient memories, and the original CIC sequencer; flow
completed unattended):

| Item | Result |
|---|---|
| WNS / TNS | +0.001 ns / 0 |
| WHS / THS | +0.0099 ns / 0 |
| `no_clock` / `unconstrained_internal_endpoints` | 0 / 0 |
| DSP48E2 per RX FIR channel / per TX FIR channel | 25 / 7 |
| Worst setup path | TX DMA request arbiter -> data-offload storage RAM, DMA clock domain (not in the new logic) |

**Builds with the changes in this document** (bypass gate removed, unity
power-up, CIC sequencer fix, RX FIR seed change, version `0x00010100`). Builds
1 to 3 finished unattended and failed timing; builds 4 to 6 are strategy
experiments on the same sources:

| Build | Implementation strategy | WNS / TNS (ns) | WHS / THS (ns) | Failing endpoints |
|---|---|---|---|---|
| 1 | `Performance_ExplorePostRoutePhysOpt` | -0.023 / -0.077 | +0.0096 / 0 | 9 |
| 2 (rebuild of 1, no source edits between) | `Performance_ExplorePostRoutePhysOpt` | -0.027 / -0.097 | +0.0097 / 0 | 6 |
| 3 | `Performance_RefinePlacement` | -0.007 / -0.026 | +0.0096 / 0 | 6 |
| 4 | `Performance_ExtraTimingOpt` | -0.052 / -0.405 | +0.0073 / 0 | fails |
| 5 | `Performance_WLBlockPlacementFanoutOpt` | **+0.034 / 0** | +0.0096 / 0 | 0 |
| 6 | `Performance_Explore` | **+0.030 / 0** | +0.0104 / 0 | 0 |
| 7 | `Performance_Explore`, clean rebuild from sources (`system_top.xsa`) | **+0.041 / 0** | +0.0099 / 0 | 0 |

**Gain-compensation fix builds** (branch `wweeks/cic-gain-compensation`, source
checksum `e5b810c347cc3410ef1408d946041882` on both, `check_timing` clean on
both, DSP48E2 RX 25 / TX 7 per FIR channel plus 1 per `cic_gain_comp` instance
on both):

| Build | Strategy | WNS / TNS (ns) | WHS / THS (ns) | `.xsa` md5 |
|---|---|---|---|---|
| gc-1 | `Performance_Explore` | +0.0074 / 0 | +0.0101 / 0 | `57cf16863cf5acc71636e280aa3ef0b4` |
| gc-2 (rebuild of gc-1, identical sources) | `Performance_Explore` | +0.0176 / 0 | +0.0099 / 0 | `c566d014d3afca427e7954133f34a84d` |
| gc-3 (`VERSION` bumped to `0x00010101`, source checksum `364413ca33d99066f3f235fe2e9b1267`) | `Performance_Explore` | +0.0083 / 0 | +0.0092 / 0 | `388886a757592c63349a663faa1490c4` |


- **`check_timing` and DSP counts** were checked on build 1 only: 0 `no_clock`,
  0 `unconstrained_internal_endpoints`, the same 3 unconstrained inputs and 5
  outputs as before, RX 25 and TX 7 DSP48E2 per FIR channel. Builds 2 and 3 use
  the same sources and were not re-checked for these.
- **Where it fails.** For all three builds the failing-endpoint lists are
  complete (their slacks sum to the reported TNS) and every endpoint is in
  `axi_adrv9026_tx_dma` or `adrv9026_data_offload`, in the DMA clock domain
  (`clk_out1_system_dma_clk_wiz_0`, period 3.003 ns). The endpoints are the DMA
  destination slice's `fwd_data_reg` bits and replicas, and the offload storage
  RAM's data-input and write-enable pins. None is in the TX FIR, the register
  block or the sequencer, which are in other clock domains, although the new
  logic may still have shifted placement.
- **Worst path, build 1** (BRAM in the DMA's store-and-forward memory to
  `fwd_data_reg[36]`): data path 2.857 ns of a 3.003 ns period, of which about
  0.19 ns is clock uncertainty and skew. About 1.75 ns is four cascaded BRAM
  blocks and about 1.0 ns is a single route to a LUT3 in a distant slice. The
  write-enable failures start at DMA control registers (`fwd_valid_reg`,
  `active_reg`) that appear to fan out to many offload RAM blocks; this is read
  from endpoint names, not traced in the netlist.
- **Run-to-run variation.** Builds 1 and 2 used the same tracked sources (checksum
  of `git diff HEAD` after build 2: `096c0eadae07b361b4e88042e9943817`) and the
  same packaged IP (`component.xml` from 09:09), yet differ by 4 ps in WNS, 20 ps
  in TNS and in the worst endpoint. The flow is not bit-reproducible, so a single
  passing run would have to be shipped as that specific `.xsa`, not as a rebuild
  of the commit.
- **Extra physical optimization does not help.** On build 1,
  `phys_opt_design -directive AggressiveExplore` added no cells and left WNS and
  TNS unchanged; the flow's strategy already includes a post-route physical
  optimization pass.
- **Strategy history and experiments.** Before the interpolator merge the
  strategy was `Performance_RefinePlacement`; the merge commit changed it to
  `Performance_ExplorePostRoutePhysOpt` (builds 1 and 2); build 3 reverted it in
  the working tree (uncommitted). Builds 4 to 6 were run back to back in the
  open project (`reset_run`, set strategy, `launch_runs impl_1`, about 20 to 25
  minutes each), same sources and packaged IP as builds 1 to 3. The strategies
  differ in more than the placer: ExtraTimingOpt is `place_design ExtraTimingOpt`
  + `phys_opt_design Explore` + `route_design NoTimingRelaxation`;
  WLBlockPlacementFanoutOpt is `place_design WLDrivenBlockPlacement` +
  `phys_opt_design AggressiveFanoutOpt` + `route_design Explore`; Explore is
  `Explore` in opt, place, phys_opt and route.
- **What the experiments show.** Post-place estimates were poor for all three
  (WNS -0.34 to -0.51 ns); the difference was made by physical optimization and
  routing. The spread across strategies (-0.052 to +0.034 ns WNS) is far larger
  than the 4 ps seen between identical builds 1 and 2, so the strategy does
  matter here. The two passing results are worth about +30 ps each, which is
  thin. Both routers reported "Skip PhysOpt in Router because non-negative WNS".
  The critical nets in the physical-optimization logs were the same DMA
  `fwd_data` bits and offload storage write-address/enable nets as in the failing
  builds, and most of the gain came from replicating them and re-placing cells.
- **Clean rebuild (build 7).** With `Performance_Explore` set in
  `system_project.tcl` and all generated project directories deleted, the
  full flow gave WNS +0.041 ns / TNS 0 / WHS +0.0099 ns / THS 0. `check_timing`:
  0 register pins with no clock, 0 pins unconstrained for max delay, 0 multiple
  clocks, 0 combinational loops; 3 input ports and 4 output ports without
  input/output delay (board-level; the earlier record above says 5 outputs, one
  more than now). DSP48E2 per FIR channel: RX 25, TX 7. Only this one clean
  build was made; the reproducibility repeat was skipped by choice, so the
  variation between builds (4 ps between identical builds 1 and 2, tens of
  picoseconds across strategies) is the best indication of how much margin this
  pass really has.
- **The `.xsa`.** A build that fails timing writes `system_top_bad_timing.xsa`
  under `adrv9026_zcu102.sdk/`. That file must not be used for FW testing.
  Record the source checksum and the `.xsa` timestamp next to any build that is
  handed over.
- **If the pass does not reproduce,** the remaining options are a slower DMA
  clock (a bandwidth cost) or a change at the DMA-to-offload boundary; both need
  the owner of that block (item 6 of `02_`, and limitation 5 below).

### Verification status

| Item | Status |
|---|---|
| Folded core: unity gain, latency, coefficient count, reload order | Verified in standalone simulation |
| `fir_coef_seq` (`FOLD_LOG2 = 2`) driving the core: natural-order 1..24..1 impulse response | Verified in simulation (0 mismatches) |
| Register block: reset values, pointers, RX/TX independence, load pulse per domain, bypass and busy crossings, unity power-up contents | Verified in simulation (RTL, unrelated clocks) |
| AXI byte addresses (`0xC0`-`0xD0`, `0x80`-`0x90`, CIC registers), OKAY responses, unmapped/write-only addresses | Verified in simulation through `axi_cic_decimate_ctrl` |
| TX FIR loads (first load, reload after data, second load with no data) with the input ungated | Verified in simulation of the interpolator hierarchy |
| CIC rate-change fix on the TX interpolator hierarchy (R=8, R=32) | Verified in simulation |
| CIC rate-change fix on the RX decimator (R = 32, 16, 8, 5, 4), and reproduction of the bug with the committed sequencer | Verified in simulation (exported RX hierarchy) |
| Full TX datapath (behavioral upacker model -> FIR -> CIC -> output muxes) at R = 32, 16, 8, 5, 4: pop rate = one per R cycles; unity FIR = FIR-bypassed path delayed by whole samples on channels 0 and 1; upacker underflow zeros flow through identically; zero-coefficient load silences 0/1; channels 2-7 zero; CIC bypass = raw passthrough on all 8 channels | Verified in simulation (0 failures) |
| Bypass-exit transient (filter state after leaving CIC bypass) | Only partly characterized (limitation 3) |
| Gain-compensation fix (section 1.5): real RX/TX hierarchy simulation across R = 4..32, two clean timing-passing builds | Verified in simulation and build; not merged into the FW branch; not yet on hardware |
| Everything on hardware | **Not yet verified** |

## 6. Known Limitations / Open Items

1. **Rate-change behavior on the previously validated builds.** The bug in 1.4
   was reproduced in simulation for both RX and TX with the committed
   sequencer, so those builds are expected to ignore rate values other than 4
   (the power-up rate) in both directions. Not observed on hardware. A hardware
   check: set the rate register to 8, then 32, with a known signal, and see
   whether the DAC tone frequency (TX) or the decimated data rate (RX) changes
   relative to R=4.
2. **CIC output level depends on R for some rates — FIXED, see section 1.5.**
   Root cause confirmed (a fixed output-truncation shift sized for R = 32) and
   corrected in RTL on branch `wweeks/cic-gain-compensation` (not yet merged
   into this branch, not yet on FW's build). Full R = 4..32 tables for both
   directions, before and after, are in section 1.5. Two clean builds pass
   timing with the fix in place; not yet verified on hardware.
3. **FIR path on leaving CIC bypass.** In bypass the FIR receives full-rate
   pops that its input FIFO cannot keep up with, so samples are dropped and its
   state is a gappy history when interpolation resumes. Measured effect at R = 4
   in simulation: entering interpolation at R = 4 straight from CIC bypass gave
   164 cycles (41 samples) of added delay, against 116 cycles (29 samples) when a
   rate change (which pauses pops for about 60 cycles while the CIC resets)
   preceded it. The 48 extra cycles are consistent with samples left queued in
   the FIR's input FIFO, which cannot drain when the input rate equals the FIR's
   service rate (R = 4); that mechanism is inferred, not observed. At higher R
   the input is slower than the service rate, so the queue would be expected to
   drain. A short filter-state transient after leaving bypass (on the order of
   the 47-tap length) is also expected and has not been characterized.
4. **TX channels 2-7** are not FIR-filtered (constant zero when interpolating).
5. **Setup timing in the TX DMA / data-offload path is marginal, unrelated to
   this feature.** The pre-existing `axi_adrv9026_tx_dma` ->
   `adrv9026_data_offload` storage path in the DMA clock domain has had almost
   no margin in every build (WNS +0.010, +0.003, +0.051 and +0.001 ns on earlier
   builds; -0.023, -0.027, -0.007 and -0.052 ns on four builds in section 5;
   +0.034, +0.030 and +0.041 ns with `Performance_WLBlockPlacementFanoutOpt`,
   `Performance_Explore` and a clean `Performance_Explore` rebuild). Its worst endpoint changes between builds and the
   strategy changes the result by tens of picoseconds. The durable fix is in that
   block (shared ADI code) or in the DMA clock, not in this feature; a passing
   result should be treated as tied to the specific strategy and the specific
   `.xsa`.
6. **`fir_compiler`'s `s_axis_data_tready` (TX) is not connected.** The input is
   offered on every pop and the FIR accepts one sample per 4 cycles; the input
   FIFO drops what it cannot take, which only matters in interpolation if pops
   arrive faster than every 4 cycles (R < 4, outside the supported range).
7. **Minimum interpolation rate is 4.** The folded FIR is sized for one input
   sample per 4 cycles; the TX rate range (4-32) already respects this.
8. **Coefficient memories** are arrays of flip-flops in the register block (~400
   cells for the TX copy), not block RAM. This costs registers, not
   correctness.
9. **`WAIT_CYCLES` default (256)** in `cic_cfg_seq` is a bound, not a measured
   figure; the core reset was about 47 cycles long in simulation.
