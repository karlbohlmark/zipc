# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build the library and all artifacts
zig build

# Build with optimization
zig build -Doptimize=ReleaseFast

# Run Zig unit tests
zig build test

# Run C tests
zig build run-c-tests

# Run example sender/receiver (Zig)
zig build run-sender
zig build run-receiver

# Run example sender/receiver (C++)
zig build run-c++-sender
zig build run-c++-receiver
```

## Architecture

ZIPC is a zero-copy IPC library using shared memory for fast message passing between processes.

### Core Components

- **src/zipc.zig** - Main implementation with `ZipcServerSender` and `ZipcClientReceiver` structs. Handles shared memory layout, message sending/receiving, and platform-specific blocking (futex on Linux, polling on macOS).

- **src/queue.zig** - Lock-free SPSC (single-producer, single-consumer) queue implementation with 64-byte cache-line padding between head/tail to prevent false sharing. Uses atomic load/store with acquire/release semantics.

- **src/zipc_c.zig** - C API wrapper that handles shared memory creation/mapping via `shm_open` and `mmap`.

- **src/root.zig** - Exports C API functions (`zipc_create_sender`, `zipc_create_receiver`, `zipc_send`, `zipc_receive`, `zipc_receive_blocking`, `zipc_unlink`).

### Shared Memory Layout

```
Queue Structure (128 bytes) -> Lock-free SPSC queue
Queue Items (queue_size * 8 bytes) -> Array of message lengths
Message Buffers (queue_size * message_size) -> Circular buffer
Init Flag (4 bytes) -> ZIPC_MAGIC for sync
```

### Build Configuration

Default parameters in `build.zig`:
- MESSAGE_SIZE: 1536 bytes
- QUEUE_SIZE: 64 slots

The build produces a static library (`libzipc.a`) with a C header (`zipc.h`) and pkg-config file.

### Platform Notes

- Linux: Uses futex for efficient blocking wait
- macOS: Falls back to polling (1ms intervals)
- aarch64 targets automatically use cortex_a53 CPU model
