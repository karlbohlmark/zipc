#include <stdio.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <assert.h>

#include "zipc.h"
#include "zipc_test_config.h"
#include "./test_single_thread_lock_step.h"

#define TEST_MESSAGE_1 "hello"
#define TEST_MESSAGE_2 "world"
#define TEST_MESSAGE_3 "!"

#define QUEUE_SIZE 64
#define MESSAGE_SIZE 1024

#define ZipcSender ZipcContext
#define ZipcReceiver ZipcContext

void test_single_thread_lock_step() {
    printf("test_single_thread_lock_step will unlink\n");
    zipc_unlink("/testar");
    printf("Did unlink\n");
    ZipcSender sender = zipc_create_sender("/testar", QUEUE_SIZE, MESSAGE_SIZE);
    ZipcReceiver receiver = zipc_create_receiver("/testar", QUEUE_SIZE, MESSAGE_SIZE);
    printf("Created sender and receiver\n");
    uint8_t *message = NULL;
    int message_size = 0;
    message_size = zipc_receive(&receiver, &message);
    assert(message == NULL);

    printf("Did first receive\n");  

    zipc_send(&sender, (const uint8_t *)TEST_MESSAGE_1, strlen(TEST_MESSAGE_1) + 1);
    message_size = zipc_receive(&receiver, &message);
    assert(message != NULL);
    assert(strcmp((char *)message, TEST_MESSAGE_1) == 0);
    message = NULL;

    zipc_send(&sender, (const uint8_t *)TEST_MESSAGE_2, strlen(TEST_MESSAGE_2) + 1);
    message_size = zipc_receive(&receiver, &message);
    assert(message != NULL);
    assert(message_size == strlen(TEST_MESSAGE_2) + 1);
    message = NULL;


    zipc_send(&sender, (const uint8_t *)TEST_MESSAGE_3, strlen(TEST_MESSAGE_3) + 1);
    message_size = zipc_receive(&receiver, &message);
    assert(message != NULL);
    assert(message_size == strlen(TEST_MESSAGE_3) + 1);
    message = NULL;

    // Tear down: destroy unmaps, and is idempotent; operations on a
    // destroyed context are safe no-ops.
    zipc_destroy(&receiver);
    zipc_destroy(&receiver);
    assert(receiver.queue == NULL);
    assert(zipc_receive(&receiver, &message) == 0);
    assert(message == NULL);
    zipc_destroy(&sender);
    assert(!zipc_send(&sender, (const uint8_t *)TEST_MESSAGE_1, 1));
    zipc_unlink("/testar");

    // Invalid parameters must fail cleanly: null-pointer context, not a crash.
    ZipcSender bad = zipc_create_sender("/testar-bad", 0, MESSAGE_SIZE);
    assert(bad.queue == NULL);
    assert(!zipc_send(&bad, (const uint8_t *)TEST_MESSAGE_1, 1));
    ZipcSender bad_name = zipc_create_sender("no-leading-slash", QUEUE_SIZE, MESSAGE_SIZE);
    assert(bad_name.queue == NULL);
    ZipcSender bad_slash = zipc_create_sender("/nested/name", QUEUE_SIZE, MESSAGE_SIZE);
    assert(bad_slash.queue == NULL);

    // message_size not a multiple of 4: the init flag needs padding for
    // alignment; the channel must still create and carry messages.
    zipc_unlink("/testar-odd");
    ZipcSender odd_tx = zipc_create_sender("/testar-odd", 4, 1001);
    ZipcReceiver odd_rx = zipc_create_receiver("/testar-odd", 4, 1001);
    assert(odd_tx.queue != NULL && odd_rx.queue != NULL);
    assert(zipc_send(&odd_tx, (const uint8_t *)TEST_MESSAGE_1, strlen(TEST_MESSAGE_1) + 1));
    message = NULL;
    message_size = zipc_receive(&odd_rx, &message);
    assert(message != NULL && strcmp((char *)message, TEST_MESSAGE_1) == 0);
    zipc_destroy(&odd_rx);
    zipc_destroy(&odd_tx);
    zipc_unlink("/testar-odd");

    printf("test function done\n");
}
