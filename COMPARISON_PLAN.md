# Comparison Plan: MirageOS+Unikraft vs Debian Cloud

This document outlines a plan to compare the unikernel approach with a traditional Linux distribution.

## Objectives

1. Compare boot time
2. Compare memory footprint
3. Compare image size
4. Compare attack surface
5. (Optional) Compare equivalent workload performance

## Setup

### System A: MirageOS + Unikraft (existing)

```bash
qemu-system-x86_64 \
  -machine q35 -m 512M \
  -kernel dist/hello.qemu \
  -nodefaults -nographic -serial stdio \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0
```

### System B: Debian Cloud

```bash
# Download Debian 12 cloud image (nocloud variant - no cloud-init needed)
wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2

# Run with same QEMU configuration
qemu-system-x86_64 \
  -machine q35 -m 512M \
  -drive file=debian-12-nocloud-amd64.qcow2,if=virtio,format=qcow2 \
  -nodefaults -nographic -serial stdio \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0
```

## Metrics & Methodology

### 1. Image Size

**Measurement:**
```bash
# Unikernel
ls -lh dist/hello.qemu

# Debian (raw size)
qemu-img info debian-12-nocloud-amd64.qcow2
```

**Expected results:**
| System | Size |
|--------|------|
| Unikernel | ~7.5 MB |
| Debian cloud | ~350 MB (compressed), ~2 GB (expanded) |

### 2. Boot Time

**Measurement:** Time from QEMU start to application ready.

For unikernel - time until `[init done]` message:
```bash
time (timeout 10 qemu-system-x86_64 ... 2>&1 | grep -m1 "\[init done\]")
```

For Debian - time until login prompt:
```bash
time (timeout 60 qemu-system-x86_64 ... 2>&1 | grep -m1 "login:")
```

**Alternative:** Use QEMU's `-d` flags or instrument with timestamps.

### 3. Memory Footprint

**Measurement:** Actual memory used after boot.

For unikernel - check from QEMU monitor or Unikraft stats (if available).

For Debian - after boot:
```bash
free -m
cat /proc/meminfo | grep -E "(MemTotal|MemFree|MemAvailable)"
```

**Compare:**
- Minimum RAM needed to boot
- RAM used at idle
- RAM used under load

### 4. Attack Surface

**Measurement:** Count of potential attack vectors.

| Metric | Unikernel | Debian |
|--------|-----------|--------|
| Syscalls available | 0 (no syscall boundary) | ~300+ |
| Running processes | 1 | 50+ |
| Open ports (default) | 0 | 1+ (SSH) |
| Shell access | None | Yes |
| Package manager | None | apt |
| Users | None | root + system users |
| SUID binaries | 0 | 10+ |
| Kernel modules | 0 | 50+ |

For Debian:
```bash
# Count syscalls
ausyscall --dump | wc -l

# Count processes
ps aux | wc -l

# Count open ports
ss -tuln

# Count SUID binaries
find / -perm -4000 2>/dev/null | wc -l

# Count kernel modules
lsmod | wc -l
```

### 5. Equivalent Workload (Optional)

To fairly compare performance, we need a workload that can run on both systems.

**Option A: Port the benchmark to Debian**
- Install OCaml 5.4 on Debian
- Install Irmin
- Run the same benchmark
- Compare execution time

```bash
# On Debian
apt update && apt install -y opam
opam init -y
opam switch create 5.4.0
eval $(opam env)
opam install irmin irmin-mem lwt -y

# Create and run benchmark (simplified, no Eio)
cat > bench.ml << 'EOF'
(* Lwt-based benchmark for Debian *)
...
EOF
```

**Option B: Simple memory/CPU benchmark**
- Use a language-agnostic benchmark (sysbench, stress-ng)
- Measures raw VM performance, not application stack

**Option C: Network throughput**
- Both use virtio-net
- Use iperf3 or similar
- Measures network stack efficiency

## Test Execution Plan

### Phase 1: Setup (30 min)
1. Download Debian cloud image
2. Verify both systems boot with identical QEMU flags
3. Set up measurement scripts

### Phase 2: Static Measurements (15 min)
1. Measure image sizes
2. Document attack surface metrics for both

### Phase 3: Boot Time Measurement (30 min)
1. Run 10 boot cycles for each system
2. Record time to ready state
3. Calculate mean and standard deviation

### Phase 4: Memory Measurement (30 min)
1. Boot each system
2. Record memory at idle
3. (If running workload) Record memory under load

### Phase 5: Optional Workload Comparison (2+ hours)
1. Port benchmark to Debian
2. Run identical workloads
3. Compare execution times

## Expected Outcomes

| Metric | Unikernel Advantage | Debian Advantage |
|--------|---------------------|------------------|
| Image size | 50-100x smaller | - |
| Boot time | 10-50x faster | - |
| Memory (idle) | 2-5x less | - |
| Attack surface | Minimal | - |
| Flexibility | - | Full OS capabilities |
| Debugging | - | Standard tools available |
| Ecosystem | - | All Linux software |

## Deliverables

1. `comparison_results.md` - Raw measurements and analysis
2. Scripts for reproducible measurements
3. Updated `STACK.md` with comparison data

## Notes

- Both systems use the same QEMU configuration (q35, virtio-net)
- Memory limited to 512MB for fair comparison
- Debian "nocloud" image chosen to avoid cloud-init overhead
- Consider also testing Alpine Linux as a minimal Linux baseline
