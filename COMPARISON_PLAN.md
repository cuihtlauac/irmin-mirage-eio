# Comparison Plan: MirageOS+Unikraft vs Debian Cloud

Compare the same Irmin benchmark workload running on both platforms, measuring CPU, memory, and energy consumption using `perf`.

## Objective

Run identical Irmin benchmarks on:
- **System A**: MirageOS + Unikraft unikernel
- **System B**: Debian Cloud with native OCaml

Measure: CPU cycles, instructions, cache misses, energy consumption.

## Setup

### System A: MirageOS + Unikraft (existing)

```bash
qemu-system-x86_64 -m 512M \
  -kernel dist/hello.qemu \
  -nodefaults -nographic -monitor none -serial stdio \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device VGA,id=none
```

Note: QEMU 10.x requires `-monitor none` and `-device VGA,id=none` to avoid conflicts with stdio.

### System B: Debian Cloud + OCaml

Build in Debian 12 container (correct glibc), run in minimal VM.

#### Step 1: Create benchmark source

```bash
cd /home/cuihtlauac/caml/irmin-mirage-eio
mkdir -p debian-bench
```

Create `debian-bench/bench.ml` (needs Eio_main.run wrapper for standalone execution):
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
  Eio_main.run @@ fun _env ->
  let config = Irmin_mem.config () in
  let r = Store.Repo.v config in
  init r;
  run r
```

Create `debian-bench/dune`:
```
(executable
 (name bench)
 (libraries irmin irmin.mem fmt eio_main))
```

Create `debian-bench/dune-project`:
```
(lang dune 3.0)
```

Create `debian-bench/benchmark.service`:
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
  opam install -y fmt dune eio_main

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
```

#### Step 4: Inject binary and auto-run service into image

Requires `guestfs-tools` and `guestfish` packages. Commands need sudo due to libguestfs kernel access:

```bash
cd /home/cuihtlauac/caml/irmin-mirage-eio

# Copy binary
sudo virt-copy-in -a debian-12-nocloud-amd64.qcow2 bench-linux /root/

# Copy service file
sudo virt-copy-in -a debian-12-nocloud-amd64.qcow2 debian-bench/benchmark.service /etc/systemd/system/

# Enable service and make binary executable
sudo guestfish -a debian-12-nocloud-amd64.qcow2 -i <<EOF
ln-sf /etc/systemd/system/benchmark.service /etc/systemd/system/multi-user.target.wants/benchmark.service
chmod 0755 /root/bench-linux
EOF
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
# Should show: power/energy-psys/, power/energy-pkg/, etc.
```

### Measurement Approach

Use system-wide measurement (`-a` flag) for energy counters. Pin QEMU to core 0 with `taskset` to isolate measurements. Both systems are measured for the full VM lifecycle (boot + benchmark + shutdown) for fair comparison.

### Measuring System A (Unikernel)

```bash
perf stat -a -x, -e cycles,instructions,cache-references,cache-misses,power/energy-psys/ \
  -- taskset -c 0 qemu-system-x86_64 -m 512M \
    -kernel dist/hello.qemu \
    -nodefaults -nographic -monitor none -serial stdio \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -device VGA,id=none
```

### Measuring System B (Debian)

```bash
perf stat -a -x, -e cycles,instructions,cache-references,cache-misses,power/energy-psys/ \
  -- taskset -c 0 qemu-system-x86_64 \
    -machine q35 -m 512M \
    -drive file=debian-12-nocloud-amd64.qcow2,if=virtio,format=qcow2,snapshot=on \
    -nographic -monitor none -serial stdio \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0
```

Note: `snapshot=on` prevents modifications to the disk image.

## Execution Script

```bash
#!/bin/bash
# run_comparison.sh

RESULTS_DIR="comparison_results"
mkdir -p $RESULTS_DIR

echo "=== System A: Unikernel ==="

# Warm-up run (no measurement)
echo "Warm-up run..."
taskset -c 0 qemu-system-x86_64 -m 512M \
  -kernel dist/hello.qemu \
  -nodefaults -nographic -monitor none -serial stdio \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device VGA,id=none > /dev/null 2>&1

# 5 measured runs
for i in 1 2 3 4 5; do
  echo "Unikernel Run $i/5..."
  sync

  perf stat -a -x, -e cycles,instructions,cache-references,cache-misses,power/energy-psys/ \
    -- taskset -c 0 qemu-system-x86_64 -m 512M \
      -kernel dist/hello.qemu \
      -nodefaults -nographic -monitor none -serial stdio \
      -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
      -device VGA,id=none \
    > $RESULTS_DIR/unikernel_output_$i.txt 2> $RESULTS_DIR/unikernel_perf_$i.txt
done

echo ""
echo "=== System B: Debian ==="

# Warm-up run (no measurement)
echo "Warm-up run..."
taskset -c 0 qemu-system-x86_64 \
  -machine q35 -m 512M \
  -drive file=debian-12-nocloud-amd64.qcow2,if=virtio,format=qcow2,snapshot=on \
  -nographic -monitor none -serial stdio \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 > /dev/null 2>&1

# 5 measured runs
for i in 1 2 3 4 5; do
  echo "Debian Run $i/5..."
  sync

  perf stat -a -x, -e cycles,instructions,cache-references,cache-misses,power/energy-psys/ \
    -- taskset -c 0 qemu-system-x86_64 \
      -machine q35 -m 512M \
      -drive file=debian-12-nocloud-amd64.qcow2,if=virtio,format=qcow2,snapshot=on \
      -nographic -monitor none -serial stdio \
      -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    > $RESULTS_DIR/debian_output_$i.txt 2> $RESULTS_DIR/debian_perf_$i.txt
done

echo ""
echo "=== Results ==="
echo "Unikernel runs:"
for i in 1 2 3 4 5; do
  echo "--- Run $i ---"
  cat $RESULTS_DIR/unikernel_perf_$i.txt
done

echo ""
echo "Debian runs:"
for i in 1 2 3 4 5; do
  echo "--- Run $i ---"
  cat $RESULTS_DIR/debian_perf_$i.txt
done

echo ""
echo "Results saved to $RESULTS_DIR/ (CSV format)"
```

## Expected Metrics

Output format is CSV (`-x,`): `value,,event_name,run_time,percentage,,extra_info`

On hybrid Intel CPUs (P-cores + E-cores), you'll see separate `cpu_core` and `cpu_atom` metrics.

| Metric | What it measures |
|--------|------------------|
| cycles | Total CPU cycles consumed |
| instructions | Total instructions executed |
| cache-misses | L3 cache misses (memory pressure) |
| energy-psys | Platform energy (full system) in Joules |

## Sample Results

```
=== COMPARISON SUMMARY ===

                        Unikernel (avg)     Debian (avg)        Ratio (Debian/Unikernel)
Cycles:                    1.90e+11            3.68e+11     1.94x
Instructions:              5.54e+11            9.57e+11     1.73x
Cache misses:              1.05e+09            2.34e+09     2.22x
Energy (Joules):            1027.00             1811.00     1.76x
```

## Notes

- Energy measurements use `power/energy-psys/` (platform energy) which works without root
- System-wide measurement (`-a` flag) is required for energy counters
- Measurements include full VM lifecycle (boot + benchmark + shutdown)
- The unikernel boots much faster, so proportionally more time is spent on actual benchmark work
- Debian includes Linux kernel boot, systemd initialization, etc.
- Run 1 warm-up iteration (no measurement) to prime CPU branch predictor and caches
- Run 5 measured iterations and average results for statistical significance
- Ensure system is idle during measurements
- Pin QEMU to a specific core to reduce scheduling variance:
  ```bash
  taskset -c 0 qemu-system-x86_64 ...
  ```
- Consider disabling turbo boost for more consistent results:
  ```bash
  echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
  ```
