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

Build in Debian 12 container (correct glibc), run in minimal VM.

#### Step 1: Create benchmark source

```bash
cd /home/cuihtlauac/caml/irmin-mirage-eio
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

#### Step 2: Build in Debian 12 container

```bash
cd /home/cuihtlauac/caml/irmin-mirage-eio

podman run --rm -v $PWD/debian-bench:/work:Z debian:12 bash -c '
  set -ex
  apt-get update
  apt-get install -y --no-install-recommends opam build-essential git m4 pkg-config ca-certificates

  opam init -y --disable-sandboxing
  eval $(opam env)
  opam switch create 5.2.1
  eval $(opam env)

  opam pin add irmin git+https://github.com/mirage/irmin#eio -y
  opam install -y fmt dune

  cd /work
  eval $(opam env)
  dune build bench.exe
'

cp debian-bench/_build/default/bench.exe bench-linux
```

#### Step 3: Prepare minimal Debian image

```bash
cd /home/cuihtlauac/caml/irmin-mirage-eio

# Download Debian 12 cloud image (if not already present)
wget -nc https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2

# Keep it small - no resize needed, just the binary
```

#### Step 4: Inject binary and auto-run service into image

Create systemd service file `debian-bench/benchmark.service`:
```ini
[Unit]
Description=Run Irmin benchmark and shutdown
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo "BENCHMARK_START"; /root/bench-linux; echo "BENCHMARK_END"; poweroff'
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
```

Inject files and enable service:
```bash
# Copy binary
virt-copy-in -a debian-12-nocloud-amd64.qcow2 bench-linux /root/

# Copy service file
virt-copy-in -a debian-12-nocloud-amd64.qcow2 debian-bench/benchmark.service /etc/systemd/system/

# Enable service (create symlink)
guestfish -a debian-12-nocloud-amd64.qcow2 -i \
  ln-sf /etc/systemd/system/benchmark.service /etc/systemd/system/multi-user.target.wants/benchmark.service

# Make binary executable
guestfish -a debian-12-nocloud-amd64.qcow2 -i \
  chmod 0755 /root/bench-linux
```

#### Step 5: Run benchmark (fully automated)

No user interaction required - VM boots, runs benchmark, shuts down automatically.

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

Fully automated - VM boots, script attaches perf when benchmark starts, detaches when done:

```bash
#!/bin/bash
# measure_debian.sh

RESULTS_DIR="comparison_results"
mkdir -p $RESULTS_DIR
FIFO=$(mktemp -u)
mkfifo $FIFO

# Start VM, tee output to monitor for markers
qemu-system-x86_64 \
  -machine q35 -m 512M \
  -drive file=debian-12-nocloud-amd64.qcow2,if=virtio,format=qcow2 \
  -nographic -serial mon:stdio \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 2>&1 | tee $FIFO &
QPID=$!

# Wait for BENCHMARK_START marker, then attach perf
grep -m1 "BENCHMARK_START" $FIFO
perf stat -e cycles,instructions,cache-references,cache-misses,power/energy-pkg/ \
  -o $RESULTS_DIR/debian_perf.txt -p $QPID &
PERF_PID=$!

# Wait for BENCHMARK_END marker, then stop perf
grep -m1 "BENCHMARK_END" $FIFO
kill -INT $PERF_PID

# Wait for VM to shutdown
wait $QPID

rm $FIFO
cat $RESULTS_DIR/debian_perf.txt
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
| CPU cycles | perf stat on QEMU | perf stat -p (auto-attach on marker) |
| Instructions | perf stat on QEMU | perf stat -p (auto-attach on marker) |
| Cache misses | perf stat on QEMU | perf stat -p (auto-attach on marker) |
| Energy (pkg) | perf energy-pkg | perf energy-pkg -p (auto-attach) |
| Peak memory | ps rss monitoring | ps rss monitoring |
| Wall time | time command | time benchmark only (auto) |

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

FIFO=$(mktemp -u)
mkfifo $FIFO

echo "Running Debian benchmark (automated)..."
qemu-system-x86_64 \
  -machine q35 -m 512M \
  -drive file=debian-12-nocloud-amd64.qcow2,if=virtio,format=qcow2 \
  -nographic -serial mon:stdio \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 2>&1 | tee $RESULTS_DIR/debian_output.txt | tee $FIFO &
QPID=$!

# Wait for benchmark start marker
grep -m1 "BENCHMARK_START" $FIFO > /dev/null
echo "Benchmark started, attaching perf..."
perf stat -e cycles,instructions,cache-references,cache-misses,power/energy-pkg/ \
  -o $RESULTS_DIR/debian_perf.txt -p $QPID &
PERF_PID=$!

# Wait for benchmark end marker
grep -m1 "BENCHMARK_END" $FIFO > /dev/null
echo "Benchmark finished, stopping perf..."
kill -INT $PERF_PID 2>/dev/null

# Wait for VM shutdown
wait $QPID 2>/dev/null
rm -f $FIFO

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
