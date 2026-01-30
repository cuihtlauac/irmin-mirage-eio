# Comparison Plan: MirageOS+Unikraft vs Debian Cloud

Compare the same Irmin benchmark workload running on both platforms, measuring CPU, memory, and energy consumption using `perf`.

## Objective

Run identical Irmin benchmarks on:
- **System A**: MirageOS + Unikraft unikernel
- **System B**: Debian Cloud with native OCaml

Measure: CPU cycles, memory usage, energy consumption.

## Setup

### System A: MirageOS + Unikraft (existing)

```bash
qemu-system-x86_64 \
  -machine q35 -m 512M \
  -kernel dist/hello.qemu \
  -nodefaults -nographic -serial stdio \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0
```

### System B: Debian Cloud + OCaml

Build on host (same x86_64 Linux), run in minimal VM.

#### Step 1: Build benchmark binary on host

```bash
cd /home/cuihtlauac/caml/irmin-mirage-eio

# Create a separate switch for native Linux builds
opam switch create debian-bench 5.2.1
eval $(opam env --switch=debian-bench --set-switch)

# Pin Irmin to eio branch (same as unikernel)
opam pin add irmin git+https://github.com/mirage/irmin#eio -y
opam install -y fmt dune

# Create benchmark directory
mkdir -p debian-bench
```

Create `debian-bench/bench.ml` (identical to unikernel version):
```ocaml
type t = {
  ncommits : int;
  depth : int;
  tree_add : int;
  display : int;
  clear : bool;
  gc : int;
}

let t = {
  ncommits = 1000;
  depth = 16;
  tree_add = 150;
  display = 10;
  clear = true;
  gc = 100;
}

module Store = Irmin_mem.KV.Make(Irmin.Contents.String)
let info () = Store.Info.v ~author:"author" ~message:"commit message" 0L

let times ~n ~init f =
  let rec go i k =
    if i = 0 then k init else go (i - 1) (fun r -> k (f i r))
  in
  go n Fun.id

let path ~depth n =
  let rec aux acc = function
    | i when i = depth -> List.rev (string_of_int n :: acc)
    | i -> aux (string_of_int i :: acc) (i + 1)
  in
  aux [] 0

let plot_progress n t = Fmt.epr "\rcommits: %4d/%d%!" n t

let init r =
  let tree = Store.Tree.empty () in
  let v = Store.main r in
  let tree =
    times ~n:t.depth ~init:tree (fun depth tree ->
        let paths = Array.init (t.tree_add + 1) (path ~depth) in
        times ~n:t.tree_add ~init:tree (fun n tree ->
            Store.Tree.add tree paths.(n) "init"))
  in
  Store.set_tree_exn v ~info [] tree;
  Fmt.epr "[init done]\n%!"

let run config =
  let v = Store.main config in
  Store.Tree.reset_counters ();
  let paths = Array.init (t.tree_add + 1) (path ~depth:t.depth) in
  let () =
    times ~n:t.ncommits ~init:() (fun i () ->
        let tree = Store.get_tree v [] in
        if i mod t.gc = 0 then Gc.full_major ();
        if i mod t.display = 0 then plot_progress i t.ncommits;
        let tree =
          times ~n:t.tree_add ~init:tree (fun n tree ->
              Store.Tree.add tree paths.(n) (string_of_int i))
        in
        Store.set_tree_exn v ~info [] tree;
        if t.clear then Store.Tree.clear tree)
  in
  Store.Repo.close config;
  Fmt.epr "\n[run done]\n%!"

let () =
  let config = Irmin_mem.config () in
  let r = Store.Repo.v config in
  init r;
  run r
```

Create `debian-bench/dune`:
```
(executable
 (name bench)
 (libraries irmin irmin.mem fmt))
```

Create `debian-bench/dune-project`:
```
(lang dune 3.0)
```

Build:
```bash
cd debian-bench
eval $(opam env --switch=debian-bench --set-switch)
dune build bench.exe
cp _build/default/bench.exe ../bench-linux
```

#### Step 2: Prepare minimal Debian image

```bash
cd /home/cuihtlauac/caml/irmin-mirage-eio

# Download Debian 12 cloud image
wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2

# Keep it small - no resize needed, just the binary
```

#### Step 3: Inject binary into image

```bash
virt-copy-in -a debian-12-nocloud-amd64.qcow2 bench-linux /root/
```

#### Step 4: Run benchmark

Boot the minimal Debian image and run the pre-built binary:
```bash
# Inside Debian VM (login as root, no password):
chmod +x /root/bench-linux
/root/bench-linux
```

## Measurements with perf

### Prerequisites (on host)

```bash
# Enable perf for VMs (may need root)
echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid

# Check energy measurement support (Intel RAPL)
perf list | grep energy
```

### Measuring System A (Unikernel)

```bash
# CPU cycles, instructions, cache misses
perf stat -e cycles,instructions,cache-references,cache-misses \
  qemu-system-x86_64 \
    -machine q35 -m 512M \
    -kernel dist/hello.qemu \
    -nodefaults -nographic -serial stdio \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0

# Energy consumption (Intel RAPL)
perf stat -e power/energy-pkg/ \
  qemu-system-x86_64 \
    -machine q35 -m 512M \
    -kernel dist/hello.qemu \
    -nodefaults -nographic -serial stdio \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0

# Combined measurement
perf stat -e cycles,instructions,cache-misses,power/energy-pkg/ \
  qemu-system-x86_64 \
    -machine q35 -m 512M \
    -kernel dist/hello.qemu \
    -nodefaults -nographic -serial stdio \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0
```

### Measuring System B (Debian)

```bash
perf stat -e cycles,instructions,cache-references,cache-misses,power/energy-pkg/ \
  qemu-system-x86_64 \
    -machine q35 -m 512M \
    -drive file=debian-12-nocloud-amd64.qcow2,if=virtio,format=qcow2 \
    -nographic -serial mon:stdio \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0
```

### Memory Measurement

Monitor QEMU process RSS from host (same approach for both systems):
```bash
# Run in background
qemu-system-x86_64 ... &
QPID=$!

# Sample memory every second
while kill -0 $QPID 2>/dev/null; do
  ps -o rss= -p $QPID
  sleep 1
done
```

## Test Matrix

| Measurement | System A (Unikernel) | System B (Debian) |
|-------------|---------------------|-------------------|
| CPU cycles | perf stat on QEMU | perf stat on QEMU |
| Instructions | perf stat on QEMU | perf stat on QEMU |
| Cache misses | perf stat on QEMU | perf stat on QEMU |
| Energy (pkg) | perf energy-pkg | perf energy-pkg |
| Peak memory | ps rss monitoring | ps rss monitoring |
| Wall time | time command | time command |

## Execution Script

```bash
#!/bin/bash
# run_comparison.sh

RESULTS_DIR="comparison_results"
mkdir -p $RESULTS_DIR

echo "=== System A: Unikernel ===" | tee $RESULTS_DIR/summary.txt

echo "Running unikernel benchmark..."
perf stat -e cycles,instructions,cache-references,cache-misses,power/energy-pkg/ \
  -o $RESULTS_DIR/unikernel_perf.txt \
  timeout 120 qemu-system-x86_64 \
    -machine q35 -m 512M \
    -kernel dist/hello.qemu \
    -nodefaults -nographic -serial stdio \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  2>&1 | tee $RESULTS_DIR/unikernel_output.txt

echo ""
echo "=== System B: Debian ===" | tee -a $RESULTS_DIR/summary.txt

echo "Running Debian benchmark..."
echo "Note: Start benchmark manually inside VM with:"
echo "  chmod +x /root/bench-linux && /root/bench-linux"

perf stat -e cycles,instructions,cache-references,cache-misses,power/energy-pkg/ \
  -o $RESULTS_DIR/debian_perf.txt \
  timeout 300 qemu-system-x86_64 \
    -machine q35 -m 512M \
    -drive file=debian-12-nocloud-amd64.qcow2,if=virtio,format=qcow2 \
    -nographic -serial mon:stdio \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  2>&1 | tee $RESULTS_DIR/debian_output.txt

echo ""
echo "=== Results ===" | tee -a $RESULTS_DIR/summary.txt
cat $RESULTS_DIR/unikernel_perf.txt | tee -a $RESULTS_DIR/summary.txt
cat $RESULTS_DIR/debian_perf.txt | tee -a $RESULTS_DIR/summary.txt
```

## Expected Metrics

| Metric | What it measures |
|--------|------------------|
| cycles | Total CPU cycles consumed |
| instructions | Total instructions executed |
| cache-misses | L3 cache misses (memory pressure) |
| energy-pkg | Total package energy (CPU + uncore) in Joules |
| rss | Resident Set Size (actual RAM used) |

## Notes

- Energy measurements require Intel RAPL support (most Intel CPUs since Sandy Bridge)
- AMD CPUs use different energy counters (`power/energy-pkg/` may differ)
- Run multiple iterations for statistical significance
- Ensure system is idle during measurements
- Consider disabling turbo boost for consistent results:
  ```bash
  echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
  ```
