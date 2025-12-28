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
 * @param name Shared memory name (must start with '/', max 39 chars)
 * @param queue_size Number of message slots in the queue
 * @param message_size Maximum size of each message in bytes
 * @return Initialized ZipcContext configured as receiver
 */
ZipcContext zipc_create_receiver(const char *name, uint32_t queue_size, uint32_t message_size);

/**
 * @brief Create a sender/server context
 *
 * Creates a sender and initializes the shared memory segment.
 * Should be called before zipc_create_receiver() on the same name.
 *
 * @param name Shared memory name (must start with '/', max 39 chars)
 * @param queue_size Number of message slots in the queue
 * @param message_size Maximum size of each message in bytes
 * @return Initialized ZipcContext configured as sender
 */
ZipcContext zipc_create_sender(const char *name, uint32_t queue_size, uint32_t message_size);

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
 * @param message Pointer to message data
 * @param message_size Size of message in bytes (must be <= configured message_size)
 */
void zipc_send(ZipcContext *sender, const uint8_t *message, size_t message_size);

/**
 * @brief Non-blocking receive
 *
 * Checks the queue for available messages and returns immediately.
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
 * @param receiver Pointer to receiver context
 * @param message Output: pointer to received message data (points into shared memory)
 * @param timeout_millis Maximum wait time in milliseconds (must be < 1000)
 * @return Message size in bytes, or 0 if timeout occurred
 */
uint32_t zipc_receive_blocking(ZipcContext *receiver, uint8_t **message, uint16_t timeout_millis);

/**
 * @brief Get the filesystem path for shared memory
 *
 * Returns the full path where the shared memory file is located
 * (e.g., /dev/shm/my-channel on Linux).
 *
 * @param name Shared memory name
 * @return Full filesystem path (caller should not free)
 */
char* zipc_shm_path(const char *name);

#ifdef __cplusplus
}
#endif

#endif /* LIB_ZIPC_H */