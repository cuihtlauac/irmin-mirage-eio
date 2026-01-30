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

#### Step 1: Download and prepare Debian image

```bash
cd /home/cuihtlauac/caml/irmin-mirage-eio

# Download Debian 12 cloud image
wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.qcow2

# Resize to have space for OCaml installation
qemu-img resize debian-12-nocloud-amd64.qcow2 8G
```

#### Step 2: First boot - install OCaml and dependencies

```bash
qemu-system-x86_64 \
  -machine q35 -m 2048M \
  -drive file=debian-12-nocloud-amd64.qcow2,if=virtio,format=qcow2 \
  -nographic -serial mon:stdio \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0
```

Inside Debian (login as root, no password):
```bash
# Resize filesystem to use full disk
resize2fs /dev/vda1

# Install OCaml toolchain
apt update
apt install -y opam build-essential git m4 pkg-config

# Initialize opam with OCaml 5.4
opam init -y --disable-sandboxing
eval $(opam env)
opam switch create 5.4.0
eval $(opam env)

# Install Irmin
opam install -y irmin irmin-mem fmt
```

#### Step 3: Create benchmark script on Debian

Create `/root/bench.ml`:
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
  let open Lwt.Syntax in
  let tree = Store.Tree.empty () in
  let* v = Store.main r in
  let* tree =
    let rec depth_loop d tree =
      if d > t.depth then Lwt.return tree
      else
        let paths = Array.init (t.tree_add + 1) (path ~depth:d) in
        let rec add_loop n tree =
          if n > t.tree_add then Lwt.return tree
          else
            let* tree = Store.Tree.add tree paths.(n) "init" in
            add_loop (n + 1) tree
        in
        let* tree = add_loop 1 tree in
        depth_loop (d + 1) tree
    in
    depth_loop 1 tree
  in
  let* () = Store.set_tree_exn v ~info [] tree in
  Fmt.epr "[init done]\n%!";
  Lwt.return_unit

let run r =
  let open Lwt.Syntax in
  let* v = Store.main r in
  Store.Tree.reset_counters ();
  let paths = Array.init (t.tree_add + 1) (path ~depth:t.depth) in
  let rec commit_loop i =
    if i > t.ncommits then Lwt.return_unit
    else begin
      let* tree = Store.get_tree v [] in
      if i mod t.gc = 0 then Gc.full_major ();
      if i mod t.display = 0 then plot_progress i t.ncommits;
      let rec add_loop n tree =
        if n > t.tree_add then Lwt.return tree
        else
          let* tree = Store.Tree.add tree paths.(n) (string_of_int i) in
          add_loop (n + 1) tree
      in
      let* tree = add_loop 1 tree in
      let* () = Store.set_tree_exn v ~info [] tree in
      if t.clear then Store.Tree.clear tree;
      commit_loop (i + 1)
    end
  in
  let* () = commit_loop 1 in
  let* () = Store.Repo.close r in
  Fmt.epr "\n[run done]\n%!";
  Lwt.return_unit

let main () =
  let open Lwt.Syntax in
  let config = Irmin_mem.config () in
  let* r = Store.Repo.v config in
  let* () = init r in
  let* () = run r in
  Lwt.return_unit

let () = Lwt_main.run (main ())
```

Create `/root/dune`:
```
(executable
 (name bench)
 (libraries irmin irmin.mem fmt lwt lwt.unix))
```

Create `/root/dune-project`:
```
(lang dune 3.0)
```

Compile:
```bash
cd /root
dune build bench.exe
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
perf stat -e power/energy-pkg/,power/energy-cores/,power/energy-ram/ \
  qemu-system-x86_64 \
    -machine q35 -m 512M \
    -kernel dist/hello.qemu \
    -nodefaults -nographic -serial stdio \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0

# Combined measurement
perf stat -e cycles,instructions,cache-misses,power/energy-pkg/,power/energy-cores/ \
  qemu-system-x86_64 \
    -machine q35 -m 512M \
    -kernel dist/hello.qemu \
    -nodefaults -nographic -serial stdio \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0
```

### Measuring System B (Debian)

Option 1: Measure entire VM (includes OS overhead)
```bash
perf stat -e cycles,instructions,cache-misses,power/energy-pkg/,power/energy-cores/ \
  qemu-system-x86_64 \
    -machine q35 -m 512M \
    -drive file=debian-12-nocloud-amd64.qcow2,if=virtio,format=qcow2 \
    -nographic -serial mon:stdio \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0
```

Option 2: Measure inside VM (benchmark only, requires perf in guest)
```bash
# Inside Debian VM
apt install -y linux-perf
perf stat -e cycles,instructions,cache-misses \
  ./_build/default/bench.exe
```

### Memory Measurement

For unikernel - monitor QEMU process:
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

For Debian - inside VM:
```bash
# Before benchmark
free -m > /tmp/mem_before.txt

# Run benchmark
./_build/default/bench.exe

# After benchmark
free -m > /tmp/mem_after.txt
```

## Test Matrix

| Measurement | System A (Unikernel) | System B (Debian) |
|-------------|---------------------|-------------------|
| CPU cycles | perf stat on QEMU | perf stat on QEMU |
| Instructions | perf stat on QEMU | perf stat on QEMU |
| Cache misses | perf stat on QEMU | perf stat on QEMU |
| Energy (pkg) | perf energy-pkg | perf energy-pkg |
| Energy (cores) | perf energy-cores | perf energy-cores |
| Peak memory | ps rss monitoring | ps rss + free -m |
| Wall time | time command | time command |

## Execution Script

```bash
#!/bin/bash
# run_comparison.sh

RESULTS_DIR="comparison_results"
mkdir -p $RESULTS_DIR

echo "=== System A: Unikernel ===" | tee $RESULTS_DIR/summary.txt

echo "Running unikernel benchmark..."
perf stat -e cycles,instructions,cache-references,cache-misses,power/energy-pkg/,power/energy-cores/ \
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
echo "  cd /root && perf stat ./_build/default/bench.exe"

perf stat -e cycles,instructions,cache-references,cache-misses,power/energy-pkg/,power/energy-cores/ \
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
| energy-cores | CPU core energy in Joules |
| energy-ram | DRAM energy in Joules |
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
