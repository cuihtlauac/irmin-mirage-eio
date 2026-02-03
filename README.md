# irmin-mirage-eio

An experiment in using Irmin with Eio on MirageOS using the Unikraft backend


## Dependencies

- `opam switch create . --deps-only`

## Building

```
$ mirage configure -t unikraft-qemu
$ make
```

## Running

```
$ qemu-system-x86_64 \
  -machine q35 -m 512M \
  -kernel dist/hello.qemu \
  -nodefaults -nographic -serial stdio \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0
```
