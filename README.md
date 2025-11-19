# irmin-mirage-eio

An experiment in using Irmin with Eio on MirageOS using the Unikraft backend


## Dependencies

- `opam install mirage mirage-unikraft`
- `opam pin add git+https://github.com/zshipko/eio#mirage`

## Building

```
$ mirage configure -t unikraft-qemu
$ make
```

## Running

```
$ qemu-system-x86_64 \
  -kernel dist/hello.qemu \
  -nodefaults -nographic \
  -serial stdio \
  -machine virt
```
