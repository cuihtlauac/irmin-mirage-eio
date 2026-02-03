# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Compares Irmin benchmark performance between two stacks running the same workload:

**Stack A (MirageOS):** bench.ml → Irmin → Eio → eio_unikraft → MirageOS → Unikraft → QEMU

**Stack B (Debian):** debian-bench/bench.ml → Irmin → Eio → Eio_main → Linux → Debian 12 → QEMU

Both use Irmin's **eio branch** with synchronous APIs (no Lwt).

Fork of [Zach Shipko's mirage-irmin-eio](https://github.com/zshipko/irmin-mirage-eio).

## Build Commands

### MirageOS (Stack A)

```bash
opam switch create . --deps-only
mirage configure -t unikraft-qemu --net direct --dhcp true
make                    # Full build (deps + build)
```

### Debian Benchmark (Stack B)

```bash
make -f Makefile.bench download-debian  # Download Debian 12 cloud image (3.5GB)
make -f Makefile.bench build-debian     # Build bench-linux in container
make -f Makefile.bench prepare-debian   # Inject binary into VM image (requires sudo)
```

## Running

```bash
make -f Makefile.bench run-mirage      # Run MirageOS/Unikraft interactively
make -f Makefile.bench run-debian      # Run Debian VM interactively
make -f Makefile.bench compare         # Run comparison (1 warm-up + 5 measured runs each)
```

The `compare` target measures benchmark duration only (excluding Debian's ~20s boot overhead).

## Architecture

### Key Files

| File | Purpose |
|------|---------|
| `unikernel.ml` | MirageOS functor - unikernel entry point |
| `config.ml` | MirageOS configuration - stack, network, packages |
| `bench.ml` | Unikernel benchmark: 1000 commits, depth=16, 150 tree adds |
| `debian-bench/bench.ml` | Standalone Linux version (wrapped with `Eio_main.run`) |
| `debian-bench/benchmark.service` | Systemd service for auto-run and shutdown |
| `Makefile.bench` | Benchmark targets: build, run, compare |

### Generated Files (don't edit)

`mirage configure` generates:
- Root: `Makefile`, `dune`, `dune-project`, `dune-workspace`, `dune.build`, `dune.config`
- mirage/: `main.ml`, `context`, `dune-workspace.config`, `hello-unikraft-qemu.opam`, `hello-unikraft-qemu.opam.locked`

### Build Artifacts

| File | Purpose |
|------|---------|
| `dist/hello.qemu` | MirageOS unikernel binary |
| `bench-linux` | Debian benchmark binary (built in container) |
| `debian-12-nocloud-amd64.qcow2` | Pristine Debian cloud image (base, never modified) |
| `debian-12-prepared.qcow2` | Overlay with injected binary (backs onto base) |
| `comparison_results/` | Benchmark output and timing data |

### Pinned Dependencies

The `.opam` file has `pin-depends` for custom versions:
- `irmin` from `mirage/irmin#eio` - synchronous API (no Lwt)
- `eio` variants from `cuihtlauac/eio#mirage` - Unikraft backend

## Important Notes

- **Container builds required** - VM builds run out of disk space; `build-debian` uses podman
- **prepare-debian needs sudo** - `virt-copy-in` requires root for kernel file access
- **QEMU 10.x quirks** - Need `-device VGA,id=none` and `-monitor none` flags
- **snapshot=on** - Debian VM runs use snapshot to preserve the prepared image
- **The eio branch matters** - Synchronous API eliminates Lwt overhead
