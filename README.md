# ZIPC

A zero-copy inter-process communication (IPC) library written in Zig that uses shared memory for fast message passing between processes.

## Features

- Zero-copy message passing via shared memory
- Lock-free SPSC (single-producer, single-consumer) queue with atomic operations
- Blocking receive with futex support (Linux) or polling fallback (macOS)
- Dual API: native Zig API and C-compatible API
- Cross-platform support for Linux and macOS

## Building

```bash
zig build
```

Build the static library:
```bash
zig build -Doptimize=ReleaseFast
```

## Zig API

### Types

#### `ZipcServerSender`

The sender side of the IPC channel. Creates and owns the shared memory segment.

```zig
pub const ZipcServerSender = extern struct {
    server_id: u64,
    connection_mode: ZipcConnectionMode,
    padding: [7]u8,
    name: [39:0]u8,
    params: ZipcParams,
    queue: *Queue,
    buffers: [*]u8,
    init_flag: *i32,
};
```

**Methods:**

| Method | Description |
|--------|-------------|
| `send(message: []const u8) void` | Sends a message to the queue. Copies data to shared memory and wakes the receiver. |
| `init(name, shared_mem_ptr, queue_size, message_size, server_id) ZipcServerSender` | Initializes a sender with an existing shared memory buffer. |
| `getSharedMemorySize() usize` | Returns the total size of the shared memory segment. |
| `getSharedMemoryPointer() [*]align(8) u8` | Returns a pointer to the shared memory region. |
| `dumpHex() void` | Debug: dumps the shared memory contents as hex. |
| `dumpQueueHex() void` | Debug: dumps the queue structure as hex. |

#### `ZipcClientReceiver`

The receiver side of the IPC channel. Attaches to an existing shared memory segment.

```zig
pub const ZipcClientReceiver = extern struct {
    client_id: u64,
    connection_mode: ZipcConnectionMode,
    padding: [7]u8,
    name: [39:0]u8,
    params: ZipcParams,
    queue: *Queue,
    buffers: [*]align(8) u8,
    init_flag: *i32,
};
```

**Methods:**

| Method | Description |
|--------|-------------|
| `receive() ?struct { u32, []u8 }` | Non-blocking receive. Returns `(index, message_slice)` or `null` if queue is empty. |
| `receive_blocking(timeout_ms: u16) ?struct { u32, []u8 }` | Blocking receive with timeout (max 999ms). Uses futex on Linux for efficient waiting. |
| `init(name, shared_mem_ptr, queue_size, message_size, client_id) ZipcClientReceiver` | Initializes a receiver with an existing shared memory buffer. |
| `sharedMemorySize() usize` | Returns the total size of the shared memory segment. |
| `getSharedMemoryPointer() [*]align(8) u8` | Returns a pointer to the shared memory region. |
| `dumpHex() void` | Debug: dumps the shared memory contents as hex. |
| `dumpQueueHex() void` | Debug: dumps the queue structure as hex. |

#### `ZipcParams`

Configuration parameters for the IPC channel.

```zig
pub const ZipcParams = packed struct {
    message_size: u32,  // Maximum size of each message in bytes
    queue_size: u32,    // Number of message slots in the queue
};
```

### Functions

#### `getSharedMemorySize`

```zig
pub fn getSharedMemorySize(queue_size: u32, message_size: u32) usize
```

Calculates the total shared memory size required for a given configuration.

#### `initServerSenderWithBuffer`

```zig
pub fn initServerSenderWithBuffer(
    name: [*:0]const u8,
    shared_memory: [*]align(8) u8,
    queue_size: u32,
    message_size: u32,
    server_id: u64,
) ZipcServerSender
```

Initializes a server/sender with a pre-allocated shared memory buffer.

#### `initClient`

```zig
pub fn initClient(
    name: [*:0]const u8,
    shared_memory: [*]align(8) u8,
    queue_size: u32,
    message_size: u32,
    client_id: u64,
) ZipcClientReceiver
```

Initializes a client/receiver with an existing shared memory buffer.

### Zig Example

**Sender:**
```zig
const std = @import("std");
const Zipc_c = @import("zipc_c.zig");

pub fn main() !void {
    const queue_size = 8;
    const message_size = 1536;
    const zipc_path = "/my-zipc-path";

    var sender = Zipc_c.zipc_create_sender(zipc_path, queue_size, message_size);

    while (true) {
        const message = "hello!";
        sender.send(message);
        std.time.sleep(200_000_000); // 200ms
    }
}
```

**Receiver:**
```zig
const std = @import("std");
const Zipc_c = @import("zipc_c.zig");

pub fn main() !void {
    const queue_size = 8;
    const message_size = 1536;
    const zipc_path = "/my-zipc-path";

    var receiver = Zipc_c.zipc_create_receiver(zipc_path, queue_size, message_size);

    while (receiver.receive_blocking(800)) |item| {
        _, const message_slice = item;
        std.debug.print("received message of len: {}\n", .{message_slice.len});
    }
}
```

---

## C API

### Header

Include the header file:
```c
#include "zipc.h"
```

### Types

#### `ZipcContext`

Opaque context structure for both sender and receiver.

```c
typedef struct {
    uint64_t id;           // Unique identifier (generated from PID and timestamp)
    uint8_t mode;          // ZIPC_MODE_SERVER (0) or ZIPC_MODE_CLIENT (1)
    uint8_t padding[7];
    char name[40];         // Shared memory name (null-terminated, max 39 chars)
    ZipcParams params;     // Queue configuration
    ZipcQueue *queue;      // Pointer to the lock-free queue
    void *buffers;         // Pointer to message buffers
    int32_t *init_flag;    // Initialization synchronization flag
} ZipcContext;
```

#### `ZipcParams`

```c
typedef struct {
    uint32_t message_size;  // Maximum size of each message in bytes
    uint32_t queue_size;    // Number of message slots in the queue
} ZipcParams;
```

#### Constants

```c
#define ZIPC_MODE_SERVER 0
#define ZIPC_MODE_CLIENT 1
```

### Functions

#### `zipc_create_sender`

```c
ZipcContext zipc_create_sender(const char *name, uint32_t queue_size, uint32_t message_size);
```

Creates a sender context and initializes the shared memory segment.

**Parameters:**
- `name`: Shared memory name (must start with `/`, max 39 characters)
- `queue_size`: Number of message slots in the queue
- `message_size`: Maximum size of each message in bytes

**Returns:** Initialized `ZipcContext` configured as sender.

---

#### `zipc_create_receiver`

```c
ZipcContext zipc_create_receiver(const char *name, uint32_t queue_size, uint32_t message_size);
```

Creates a receiver context and attaches to an existing shared memory segment.

**Parameters:**
- `name`: Shared memory name (must match the sender's name)
- `queue_size`: Number of message slots (must match sender)
- `message_size`: Maximum message size (must match sender)

**Returns:** Initialized `ZipcContext` configured as receiver.

---

#### `zipc_send`

```c
void zipc_send(ZipcContext *sender, const uint8_t *message, size_t message_size);
```

Sends a message through the IPC channel.

**Parameters:**
- `sender`: Pointer to the sender context
- `message`: Pointer to the message data
- `message_size`: Size of the message in bytes (must be <= configured message_size)

---

#### `zipc_receive`

```c
uint32_t zipc_receive(ZipcContext *receiver, uint8_t **message);
```

Non-blocking receive. Checks the queue and returns immediately.

**Parameters:**
- `receiver`: Pointer to the receiver context
- `message`: Output pointer that will be set to the message data

**Returns:** Message size in bytes, or `0` if no message is available.

---

#### `zipc_receive_blocking`

```c
uint32_t zipc_receive_blocking(ZipcContext *receiver, uint8_t **message, uint16_t timeout_millis);
```

Blocking receive with timeout. Waits for a message using futex (Linux) or polling (macOS).

**Parameters:**
- `receiver`: Pointer to the receiver context
- `message`: Output pointer that will be set to the message data
- `timeout_millis`: Maximum time to wait in milliseconds (must be < 1000)

**Returns:** Message size in bytes, or `0` if timeout occurred.

---

#### `zipc_unlink`

```c
void zipc_unlink(const char *name);
```

Removes the shared memory segment from the filesystem.

**Parameters:**
- `name`: Shared memory name to unlink

---

#### `zipc_shm_path`

```c
char* zipc_shm_path(const char *name);
```

Returns the full filesystem path to the shared memory file.

**Parameters:**
- `name`: Shared memory name

**Returns:** Full path (e.g., `/dev/shm/my-zipc-path` on Linux).

### C Example

**Sender (C++):**
```cpp
#include <iostream>
#include <chrono>
#include <thread>
#include "zipc.h"

#define QUEUE_SIZE 64
#define MESSAGE_SIZE 1024

int main() {
    ZipcContext sender = zipc_create_sender("/my-zipc-path", QUEUE_SIZE, MESSAGE_SIZE);

    const char* message = "hello";
    while (true) {
        zipc_send(&sender, (const uint8_t*)message, strlen(message) + 1);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }

    // Clean up when done
    zipc_unlink("/my-zipc-path");
    return 0;
}
```

**Receiver (C++):**
```cpp
#include <iostream>
#include <chrono>
#include <thread>
#include "zipc.h"

#define QUEUE_SIZE 64
#define MESSAGE_SIZE 1024

int main() {
    ZipcContext receiver = zipc_create_receiver("/my-zipc-path", QUEUE_SIZE, MESSAGE_SIZE);

    uint8_t *received_msg = nullptr;
    while (true) {
        uint32_t len = zipc_receive(&receiver, &received_msg);
        if (len > 0) {
            std::cout << "Received: " << (char*)received_msg << std::endl;
        } else {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }

    return 0;
}
```

**Sender/Receiver (C):**
```c
#include <stdio.h>
#include <string.h>
#include "zipc.h"

#define QUEUE_SIZE 64
#define MESSAGE_SIZE 1024

int main() {
    // Clean up any previous shared memory
    zipc_unlink("/test");

    // Create sender and receiver
    ZipcContext sender = zipc_create_sender("/test", QUEUE_SIZE, MESSAGE_SIZE);
    ZipcContext receiver = zipc_create_receiver("/test", QUEUE_SIZE, MESSAGE_SIZE);

    // Send a message
    const char* msg = "Hello, IPC!";
    zipc_send(&sender, (const uint8_t*)msg, strlen(msg) + 1);

    // Receive the message
    uint8_t *received = NULL;
    uint32_t len = zipc_receive(&receiver, &received);

    if (len > 0) {
        printf("Received: %s\n", (char*)received);
    }

    // Clean up
    zipc_unlink("/test");
    return 0;
}
```

---

## Architecture

### Shared Memory Layout

```
+-------------------+
| Queue Structure   |  <- Lock-free SPSC queue (head/tail with 64-byte padding)
| (128 bytes)       |
+-------------------+
| Queue Items       |  <- Array of message lengths (queue_size * 8 bytes)
| (queue_size * 8)  |
+-------------------+
| Message Buffers   |  <- Circular buffer for messages
| (queue_size *     |
|  message_size)    |
+-------------------+
| Init Flag         |  <- ZIPC_MAGIC (4 bytes) for initialization sync
| (4 bytes)         |
+-------------------+
```

### Queue Implementation

The queue uses a lock-free single-producer single-consumer design:
- 64-byte cache-line padding between head and tail to prevent false sharing
- Atomic load/store with acquire/release semantics
- Futex-based blocking on Linux for efficient waiting

### Platform Support

| Feature | Linux | macOS |
|---------|-------|-------|
| Shared Memory | POSIX shm_open | shm_open |
| Blocking Wait | futex | Polling |
| Architectures | x86_64, aarch64 | x86_64, aarch64 |

## License

MIT License
