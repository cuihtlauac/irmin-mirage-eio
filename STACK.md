# Application to Hardware Stack

This document describes the complete software stack from the Irmin benchmark application down to the physical hardware.

## Stack Overview

```
+-----------------------------------------------------------+
|                    Application Layer                       |
|  bench.ml - Irmin benchmark using in-memory store          |
+-----------------------------------------------------------+
                            |
                            v
+-----------------------------------------------------------+
|                    Concurrency Layer                       |
|  Eio - Effects-based structured concurrency                |
|  Lwt_eio - Bridge between Lwt (Irmin) and Eio              |
+-----------------------------------------------------------+
                            |
                            v
+-----------------------------------------------------------+
|                    Unikernel Layer                         |
|  MirageOS - Library OS for building unikernels             |
|  mirage-unikraft - Unikraft-specific drivers               |
+-----------------------------------------------------------+
                            |
                            v
+-----------------------------------------------------------+
|                    Unikraft Layer                          |
|  Unikraft - Modular library operating system               |
+-----------------------------------------------------------+
                            |
                            v
+-----------------------------------------------------------+
|                  Virtualization Layer                      |
|  QEMU - Hardware emulator and virtualizer                  |
+-----------------------------------------------------------+
                            |
                            v
+-----------------------------------------------------------+
|                      Host Layer                            |
|  Linux kernel with KVM (optional)                          |
+-----------------------------------------------------------+
                            |
                            v
+-----------------------------------------------------------+
|                   Physical Hardware                        |
|  x86_64 CPU, RAM, peripherals                              |
+-----------------------------------------------------------+
```

## Layer Details

### Application Layer

```
bench.ml (Irmin benchmark)
    |
    +-- Irmin_mem.KV - In-memory key-value store
    |   +-- Tree operations (add, get)
    |   +-- Commits with content-addressed storage
    |
    +-- Lwt_eio.run_lwt - Bridges Lwt (used by Irmin) to Eio
```

The benchmark creates a tree structure with configurable depth and performs repeated commits, testing Irmin's performance in a unikernel environment.

### Concurrency Layer

```
Eio (Effects-based I/O)
    |
    +-- Structured concurrency with fibers
    +-- Uses OCaml 5.x effect handlers
    |
    +-- eio_unikraft - Eio backend for Unikraft
        +-- Fiber scheduling
        +-- I/O event handling
```

Eio provides modern, structured concurrency using OCaml 5's effect system. The `eio_unikraft` backend integrates with Unikraft's event loop and scheduler.

### Unikernel Layer (MirageOS)

```
unikernel.ml + mirage/main.ml (generated)
    |
    +-- Mirage runtime
    |   +-- Lifecycle management
    |   +-- Logging infrastructure
    |
    +-- TCP/IP stack (mirage-tcpip)
    |   +-- Ethernet driver
    |   +-- ARP protocol
    |   +-- IPv4/IPv6
    |   +-- TCP, UDP, ICMP
    |
    +-- mirage-unikraft drivers
        +-- Network device (virtio-net)
        +-- Console (serial)
        +-- Time/clock services
```

MirageOS provides a library OS approach where operating system functionality is compiled directly into the application as OCaml libraries.

### Unikraft Layer (Library OS)

```
Unikraft kernel
    |
    +-- Core components (as libraries)
    |   +-- ukboot - Boot sequence
    |   +-- ukalloc - Memory allocator (buddy allocator)
    |   +-- uksched - Cooperative scheduler
    |   +-- ukconsole - Console output
    |   +-- uknetdev - Network device abstraction
    |
    +-- Platform code (kvmplat)
    |   +-- x86_64 bootstrap
    |   +-- Multiboot entry point
    |   +-- Virtual hardware drivers
    |
    +-- musl libc (minimal subset)
        +-- POSIX compatibility layer
```

Unikraft provides a modular library OS where each component (scheduler, memory allocator, drivers) is a selectable library. Only needed components are linked into the final image.

### Virtualization Layer

```
QEMU (q35 machine type)
    |
    +-- Virtual CPU
    |   +-- x86_64 emulation
    |   +-- KVM acceleration (if available)
    |
    +-- Virtual memory (512MB configured)
    |
    +-- virtio-net-pci
    |   +-- Paravirtualized network device
    |   +-- User-mode networking (NAT to host)
    |
    +-- Serial console
    |   +-- Maps to stdout
    |
    +-- SeaBIOS
        +-- Boots kernel via Multiboot protocol
```

QEMU provides hardware emulation. With KVM enabled, it uses hardware virtualization for near-native performance.

### Host Layer

```
Linux kernel
    |
    +-- KVM module (optional)
    |   +-- Hardware virtualization support
    |   +-- Uses VT-x (Intel) or AMD-V
    |
    +-- Network stack
    |   +-- Handles QEMU's user-mode NAT
    |   +-- Provides internet access to unikernel
    |
    +-- Terminal emulator
        +-- Displays serial console output
```

### Physical Hardware

```
x86_64 CPU
    +-- VT-x (Intel) or AMD-V extensions
    +-- Ring -1 (hypervisor mode) for KVM
    +-- Ring 0 (kernel mode)
    +-- Ring 3 (user mode)

RAM
    +-- Physical memory mapped to VM

NIC (not directly used)
    +-- QEMU's user-mode networking is software-only
```

## Key Architectural Differences from Traditional Systems

### Traditional Stack
```
Application
    |
    v
libc (glibc)
    |
    v
System calls
    |
    v
Linux kernel
    |
    v
Hardware
```

### Unikernel Stack
```
Application
    |
    v
MirageOS libraries
    |
    v
Unikraft (no syscall boundary)
    |
    v
Hypervisor
    |
    v
Hardware
```

**Key differences:**

1. **No syscall overhead** - Everything runs in a single address space at ring 0 (inside the VM)
2. **No process isolation** - Single application, no need for memory protection between processes
3. **Minimal image size** - Only required components are included (~7.5MB for this unikernel)
4. **Reduced attack surface** - No shell, no unnecessary services, no multi-user support
5. **Library OS model** - OS functionality is just libraries linked into the application

## Memory Layout

```
+------------------+ High addresses
|                  |
|  Heap (grows up) |
|                  |
+------------------+
|                  |
|  Stack           |
|                  |
+------------------+
|  BSS (zero init) |
+------------------+
|  Data (init)     |
+------------------+
|  Text (code)     |
+------------------+
|  Multiboot info  |
+------------------+ Low addresses
```

The entire unikernel runs in a flat address space with no virtual memory complexity.

## Boot Sequence

1. **QEMU/SeaBIOS** loads kernel via Multiboot
2. **Unikraft kvmplat** initializes x86_64 CPU state
3. **ukboot** sets up memory allocator and scheduler
4. **OCaml runtime** initializes
5. **MirageOS runtime** configures logging and network
6. **Application** (`Bench.main`) starts executing

## Network Path

```
Application (Irmin - not using network in this benchmark)
    |
    v
mirage-tcpip (pure OCaml TCP/IP stack)
    |
    v
mirage-net-unikraft (virtio-net driver)
    |
    v
Unikraft uknetdev abstraction
    |
    v
virtio-net-pci (paravirtualized)
    |
    v
QEMU user-mode networking
    |
    v
Host Linux network stack
    |
    v
Physical NIC (if accessing external network)
```

The TCP/IP stack is implemented entirely in OCaml - there's no kernel network stack.
