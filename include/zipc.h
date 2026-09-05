/* SPDX-License-Identifier: MIT */
/**
 * @file zipc.h
 * @brief ZIPC - Zero-copy Inter-Process Communication Library
 *
 * A high-performance IPC library using shared memory and lock-free queues
 * for fast message passing between processes.
 *
 * @example
 * // Sender
 * ZipcContext sender = zipc_create_sender("/my-channel", 64, 1024);
 * zipc_send(&sender, (uint8_t*)"hello", 6);
 *
 * // Receiver
 * ZipcContext receiver = zipc_create_receiver("/my-channel", 64, 1024);
 * uint8_t *msg;
 * uint32_t len = zipc_receive(&receiver, &msg);
 */
#ifndef LIB_ZIPC_H
#define LIB_ZIPC_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/** @brief Context mode: server/sender side */
#define ZIPC_MODE_SERVER 0
/** @brief Context mode: client/receiver side */
#define ZIPC_MODE_CLIENT 1

/** @brief Opaque queue structure (internal use) */
typedef struct ZipcQueue ZipcQueue;

/**
 * @brief IPC channel configuration parameters
 */
typedef struct {
    uint32_t message_size;  /**< Maximum size of each message in bytes */
    uint32_t queue_size;    /**< Number of message slots in the queue */
} ZipcParams;

/**
 * @brief IPC context structure for sender or receiver
 *
 * This structure is returned by zipc_create_sender() and zipc_create_receiver().
 * The same structure type is used for both roles; the mode field indicates which.
 */
typedef struct {
    uint64_t id;            /**< Unique identifier (PID + timestamp based) */
    uint8_t mode;           /**< ZIPC_MODE_SERVER or ZIPC_MODE_CLIENT */
    uint8_t padding[7];     /**< Padding for alignment */
    char name[40];          /**< Shared memory name (null-terminated) */
    ZipcParams params;      /**< Queue configuration */
    ZipcQueue *queue;       /**< Pointer to the lock-free queue */
    void *buffers;          /**< Pointer to message buffer region */
    int32_t *init_flag;     /**< Initialization synchronization flag */
    /* Total size: 88 bytes */
} ZipcContext;

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Create a receiver/client context
 *
 * Creates a receiver that attaches to the shared memory segment.
 * The sender should be created first to initialize the shared memory.
 *
 * ERRORS: on failure (invalid name or parameters, shm open/resize/map
 * failure, /dev/shm out of space) the reason is logged to stderr and the
 * returned context has queue == NULL. Check it:
 *
 *     ZipcContext rx = zipc_create_receiver("/chan", 64, 1024);
 *     if (rx.queue == NULL) { ... handle failure ... }
 *
 * Every zipc call on such a context is a safe no-op (receive returns 0,
 * send returns false).
 *
 * @param name Shared memory name (must start with '/', contain no further
 *             '/', max 39 chars; macOS enforces a shorter OS limit of 31)
 * @param queue_size Number of message slots in the queue (min 2; usable
 *                   capacity is queue_size - 1, one slot stays unused to
 *                   distinguish full from empty)
 * @param message_size Maximum size of each message in bytes (min 1)
 * @return Initialized ZipcContext configured as receiver
 */
ZipcContext zipc_create_receiver(const char *name, uint32_t queue_size, uint32_t message_size);

/**
 * @brief Create a sender/server context
 *
 * Creates a sender and initializes the shared memory segment.
 * Should be called before zipc_create_receiver() on the same name.
 * On Linux the full segment is preallocated at create time (fallocate), so
 * shm space exhaustion fails here rather than as a SIGBUS during a later
 * send; on platforms without preallocation exhaustion can still surface
 * later.
 *
 * ERRORS: same contract as zipc_create_receiver() - on failure the returned
 * context has queue == NULL and the reason is logged to stderr.
 *
 * @param name Shared memory name (must start with '/', contain no further
 *             '/', max 39 chars; macOS enforces a shorter OS limit of 31)
 * @param queue_size Number of message slots in the queue (min 2; usable
 *                   capacity is queue_size - 1)
 * @param message_size Maximum size of each message in bytes (min 1)
 * @return Initialized ZipcContext configured as sender
 */
ZipcContext zipc_create_sender(const char *name, uint32_t queue_size, uint32_t message_size);

/**
 * @brief Destroy a context created by zipc_create_sender/receiver
 *
 * Unmaps the shared memory and sets the context's pointers to NULL. Any
 * message pointer previously returned by zipc_receive() is invalid after
 * this call. The shared memory segment itself stays in the filesystem (and
 * keeps its contents for other attached processes) until zipc_unlink().
 *
 * Safe to call on an already-destroyed or failed context. After the call,
 * zipc_send/zipc_receive on the context are safe no-ops.
 *
 * Not thread-safe: the context must not be concurrently in use by another
 * thread when destroy runs. The no-op guarantee applies to calls made after
 * destroy returns, as observed by the same thread or under external
 * synchronization.
 *
 * @param context Sender or receiver context to destroy
 */
void zipc_destroy(ZipcContext *context);

/**
 * @brief Remove shared memory segment
 *
 * Unlinks the shared memory file from the filesystem. Should be called
 * when the IPC channel is no longer needed.
 *
 * @param name Shared memory name to unlink
 */
void zipc_unlink(const char *name);

/**
 * @brief Send a message
 *
 * Copies the message to shared memory and enqueues it. On Linux,
 * wakes the receiver using futex if it's waiting.
 *
 * @param sender Pointer to sender context
 * @param message Pointer to message data. Must not point into this channel's
 *                own buffer region.
 * @param message_size Size of message in bytes
 * @return true if the message was published; false if it exceeds the channel's
 *         configured message_size, or the queue is full. Nothing is written to
 *         shared memory when false is returned.
 */
bool zipc_send(ZipcContext *sender, const uint8_t *message, size_t message_size);

/**
 * @brief Non-blocking receive
 *
 * Checks the queue for available messages and returns immediately.
 *
 * The message is not copied: *message points into the shared memory segment,
 * at the slot the sender wrote it to.
 *
 * LIFETIME: the returned pointer is valid until the next zipc_receive() or
 * zipc_receive_blocking() call on this context. Copy the data out before that
 * call if you need to keep it. The sender cannot reclaim the slot while you
 * hold it - it reports a full queue instead - but your next receive releases
 * it, after which the sender may overwrite it at any time.
 *
 * This makes the common "handle each message, then ask for the next one" loop
 * safe with no copy. It does NOT make it safe to collect several pointers
 * before processing them, or to hand a pointer to another thread that may
 * outlive the next receive call. Both need a copy.
 *
 * Note: a zero-length message and an empty queue both return 0; they are
 * distinguished by *message, which is non-NULL for a dequeued zero-length
 * message and NULL when the queue was empty.
 *
 * @param receiver Pointer to receiver context
 * @param message Output: pointer to received message data (points into shared memory)
 * @return Message size in bytes, or 0 if queue is empty
 */
uint32_t zipc_receive(ZipcContext *receiver, uint8_t **message);

/**
 * @brief Blocking receive with timeout
 *
 * Waits for a message with the specified timeout. Uses futex on Linux
 * for efficient waiting, or polling on other platforms.
 *
 * The message is not copied and the returned pointer has the same lifetime as
 * for zipc_receive(): valid until the next receive call on this context.
 *
 * @param receiver Pointer to receiver context
 * @param message Output: pointer to received message data (points into shared memory)
 * @param timeout_millis Maximum wait time in milliseconds (0..65535)
 * @return Message size in bytes, or 0 if timeout occurred
 */
uint32_t zipc_receive_blocking(ZipcContext *receiver, uint8_t **message, uint16_t timeout_millis);

/**
 * @brief Get the filesystem path for shared memory
 *
 * Returns the OS-level identifier of the shared memory object: the full
 * filesystem path on Linux (e.g. /dev/shm/my-channel); on macOS shm objects
 * are kernel names rather than files, so the name itself is returned.
 *
 * The result points into a static buffer: it is valid until the next
 * zipc_shm_path() call from any thread, and must not be freed. Returns an
 * empty string for an invalid name.
 *
 * @param name Shared memory name
 * @return Full filesystem path (caller should not free)
 */
char* zipc_shm_path(const char *name);

#ifdef __cplusplus
}
#endif

#endif /* LIB_ZIPC_H */