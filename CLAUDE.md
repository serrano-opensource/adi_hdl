# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository overview

This is Analog Devices' HDL reference-design repository: reusable Verilog/VHDL
IP cores plus the Tcl scripts needed to build them into complete FPGA
reference designs (AMD/Xilinx Vivado or Intel Quartus) pairing an ADI
evaluation board with a specific FPGA carrier board (e.g. ZCU102, VCU118).

## Build commands

- **Build one project** (generates a bitstream):
  ```
  cd projects/<design>/<carrier-board> && make
  ```
  e.g. `cd projects/adrv9026/zcu102 && make`. Requires Vivado sourced first
  (`source <vivado_install>/settings64.sh`). Parameters are overridden as
  make variables, e.g. `make ORX_ENABLE=1 RX_JESD_M=4`; the recognized names
  and their defaults are declared per-project via `get_env_param` calls in
  that project's `system_project.tcl`. Passing any override causes the build
  to land in a variable-named subdirectory instead of the project root, so
  parallel configs never collide.
  - Output: `<proj>.sdk/system_top.xsa` and `<proj>.runs/impl_1/system_top.bit`.
  - `make lib` in a project dir builds only its declared library IP
    dependencies (`LIB_DEPS` in that project's `Makefile`) — a fast way to
    catch IP-packaging errors before running a full synth/impl/bitstream build.
  - `make clean` / `make clean-all` remove build artifacts (`clean-all` also
    cleans the library IPs the project depends on).
- **Build everything** from repo root: `make all` (all projects, all boards —
  very long). Build a single project from repo root:
  `make <design>.<carrier-board>` (e.g. `make adv7511.zed`).
- **Build/repackage one library IP**: `cd library/<ip_name> && make` (runs its
  `<ip>_ip.tcl` through Vivado batch mode, producing `component.xml`).
  `make lib` from repo root builds every library IP.

## Lint

- `python .github/scripts/check_guideline.py -p <file1> <file2> ...` — checks
  the given files against the ADI HDL coding guidelines; this is exactly what
  CI runs against a PR's changed files, and a failure blocks review/merge.
  `-m <module_name>` instead checks every instantiation of a given module
  across the repo.

## Testing

Per-IP Verilog testbenches live in `library/<ip>/tb/`. Each testbench is a
tiny script (e.g. `library/common/tb/ad_mux_tb`) that sets `SOURCE` to the
list of `.v` files it needs, then sources the shared `run_tb.sh` dispatcher.
- Run a single test: `cd library/<ip>/tb && ./<testbench_name>` (defaults to
  Icarus Verilog via `iverilog`).
- Run against a different simulator: `SIMULATOR=xsim ./<testbench_name>`
  (also supports `modelsim`, `xcelium`).

## Documentation

`docs/` is a Sphinx site; per-IP register maps are sourced from
`docs/regmap/<ip>.txt` files (pulled in via an `hdl-regmap` directive) rather
than being hand-written into the `.rst` pages — update the regmap `.txt`
whenever a register changes. To build locally: build the libraries first
(`cd library && make`), then `cd docs && pip install -r requirements.txt && make html`
(output in `docs/_build/html`).

## Architecture

### Repository layout

- `library/` — reusable IP cores, one directory per core. Each has its own
  `Makefile` (auto-discovered by `library/Makefile` via
  `find . -mindepth 2 -name Makefile`, so a new IP needs no top-level
  registration) and an `<ip>_ip.tcl` Vivado packaging script, often plus a
  `tb/` testbench directory.
- `projects/<design>/<carrier-board>/` — one buildable reference design per
  (design, carrier-board) pair. Contains `system_top.v` (pad/IOB-level I/O
  only — no real logic), `system_constr.xdc`, `system_project.tcl` (declares
  parameter defaults and calls `adi_project` / `adi_project_run`),
  `system_bd.tcl` (sources the carrier board's common BD script, then the
  design's shared block-design script), and an auto-generated `Makefile`
  (`M_DEPS`/`LIB_DEPS`) — despite its "Auto-generated, do not modify" header,
  this file must be hand-edited whenever a new source file or library IP
  dependency is introduced; there's no regeneration script.
- `projects/<design>/common/<design>_bd.tcl` — for a design supported on
  multiple carrier boards, all real IP instantiation/wiring lives in this one
  shared file; each carrier's `system_bd.tcl` just sources it after its own
  board setup.
- `projects/common/<carrier-board>/` — reusable per-carrier-board Tcl (PS/MPSoC
  config, pinouts) shared across every design built for that board.
- `projects/common/xilinx/` and `projects/scripts/` — shared Xilinx-only Tcl
  helpers used by most designs' block-design scripts: `adi_board.tcl` defines
  `ad_ip_instance`, `ad_connect`, `ad_cpu_interconnect`; `adi_project_xilinx.tcl`
  defines `adi_project`/`adi_project_run` (the create-BD → validate →
  generate-target → synth → impl → bitstream pipeline); `jesd204/scripts/jesd204.tcl`
  provides the JESD204 link/transport-layer creation procs shared by every
  JESD204-based design.

### Block-design construction pattern (Xilinx projects)

Every Xilinx project builds its design the same way via `adi_project`: create
a Vivado project → `create_bd_design "system"` → `source system_bd.tcl`
(which recursively sources carrier + design common Tcl) → `validate_bd_design`
→ `generate_target` → `adi_project_run` (synth/impl/bitstream). IP
instantiation inside these scripts goes through the small set of reusable
procs in `adi_board.tcl` rather than raw Vivado Tcl — `ad_ip_instance <vlnv>
<instance-name> [config-list]` to instantiate, `ad_connect <a> <b>` to wire
ports/pins, `ad_cpu_interconnect <base-addr> <instance>` to map a new AXI-lite
peripheral into the Zynq/MPSoC processor's address space (for Zynq
UltraScale+ parts specifically, addresses in the `0x4000_0000`-`0x4fff_ffff`
HDL range get `+0x4000_0000` added to produce the physical address Linux
actually sees).

### Common reusable primitives

- `library/common/up_axi.v` — AXI4-Lite-to-simple-register-bus adapter; the
  standard way most custom control/status IPs in this repo expose registers.
- `library/common/up_xfer_cntrl.v` — toggle-handshake CDC that transfers a
  whole multi-bit control word atomically between the AXI-lite clock domain
  and a design clock domain. Prefer this over `library/util_cdc/sync_bits.v`
  whenever more than one bit of a control word can change on the same write —
  `sync_bits` is only safe for signals where at most one bit changes per
  clock (e.g. a single enable bit or a Gray-coded counter).
- `library/common/ad_bus_mux.v` — 2-way data/valid/enable mux; the standard
  building block for a bypass path around an optional processing stage.
- JESD204-based designs share `adi_axi_jesd204_{rx,tx}_create` and
  `adi_tpl_jesd204_{rx,tx}_create` to instantiate the link layer and
  transport-layer (parallel sample) cores; `library/util_pack/util_cpack2` /
  `util_upack2` then pack/unpack the resulting per-converter parallel
  channels into/from the wide bus that `library/axi_dmac/` DMAs to/from
  processor memory. `axi_dmac`'s raw `fifo_wr_*`/`fifo_rd_*` side is a plain
  synchronous bus with no ready/valid handshake, so an intermittent (e.g.
  decimated) strobe on it is valid.

### Licensing and versioning conventions

- Individual files/modules may carry their own distinct license terms (GPL2,
  ADIBSD, LGPL, etc., stated in the file header) — check the header of a file
  before assuming repo-wide licensing applies.
- IPs follow Semantic Versioning; devicetree `compatible` strings encode only
  the **major** version (`adi,axi-my-ip-v1`), and drivers are expected to
  branch on the IP's `VERSION` register for feature detection rather than on
  the minor/patch numbers.
