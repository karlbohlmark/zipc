/* SPDX-License-Identifier: MIT */
#ifndef LIB_ZIPC_H
#define LIB_ZIPC_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#define ZIPC_MODE_SERVER 0
#define ZIPC_MODE_CLIENT 1

typedef struct ZipcQueue ZipcQueue;

typedef struct {
    uint32_t message_size;
    uint32_t queue_size;
} ZipcParams;

typedef struct {
    uint64_t id;
    uint8_t mode;
    uint8_t padding[7];
    char name[40];
    ZipcParams params;
    ZipcQueue *queue;
    void *buffers;
    int32_t *init_flag;
    // 88 bytes
} ZipcContext;

#ifdef __cplusplus
extern "C" {
#endif

ZipcContext zipc_1536_64_create_receiver(const char *name);
ZipcContext zipc_1536_64_create_sender(const char *name);
void zipc_unlink(const char *name);

void zipc_1536_64_send(ZipcContext *sender, const uint8_t *message, size_t message_size);
uint32_t zipc_1536_64_receive(ZipcContext *receiver, uint8_t **message);

uint32_t zipc_1536_64_receive_blocking(ZipcContext *receiver, uint8_t **message, uint16_t timeout_millis);

size_t zipc_1536_64_receiver_wait_for_initialization(ZipcContext *receiver);

char* zipc_shm_path(const char *name);

#ifdef __cplusplus
}
#endif
#endif // LIB_ZIPC_H