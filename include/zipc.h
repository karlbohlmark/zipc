#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>

#define ZIPC_MESSAGE_SIZE 8
#define ZIPC_QUEUE_SIZE 4

typedef struct {
    uint64_t buffer[ZIPC_QUEUE_SIZE]; // Circular buffer for the queue
    _Atomic uint32_t head;             // Consumer index (atomic for thread safety)
    // uint8_t padding[64];               // Padding to prevent false sharing
    _Atomic uint32_t tail;             // Producer index (atomic for thread safety)
} ZipcQueue;

typedef struct {
    uint32_t message_size;
    uint32_t queue_size;
} ZipcParams;

typedef struct {
    uint64_t client_id;
    const char *name;
    ZipcParams params;
    ZipcQueue *queue;
    uint8_t (*buffers)[ZIPC_QUEUE_SIZE][ZIPC_MESSAGE_SIZE];
    int32_t *init_flag;
} ZipcReceiver;

typedef struct {
    uint64_t server_id;
    const char *name;
    ZipcParams params;
    ZipcQueue *queue;
    uint8_t (*buffers)[ZIPC_QUEUE_SIZE][ZIPC_MESSAGE_SIZE];
    int32_t *init_flag;
} ZipcSender;

ZipcReceiver zipc_1536_64_create_receiver(const char *name);
ZipcSender zipc_1536_64_create_sender(const char *name);

uint32_t zipc_1536_64_send(ZipcSender *sender, const uint8_t *message, size_t message_size);
uint32_t zipc_1536_64_receive(ZipcReceiver *receiver, uint8_t **message);

size_t zipc_1536_64_receiver_wait_for_initialization(ZipcReceiver *receiver);

char* zipc_shm_path(const char *name);