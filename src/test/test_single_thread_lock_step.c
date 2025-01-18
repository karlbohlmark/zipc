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

#define ZipcSender ZipcContext
#define ZipcReceiver ZipcContext

void test_single_thread_lock_step() {
    zipc_unlink("/testar");
    ZipcSender sender = zipc_1536_64_create_sender("/testar");
    ZipcReceiver receiver = zipc_1536_64_create_receiver("/testar");
    uint8_t *message = NULL;
    int message_size = 0;
    message_size = zipc_1536_64_receive(&receiver, &message);
    assert(message == NULL);

    zipc_1536_64_send(&sender, (const uint8_t *)TEST_MESSAGE_1, strlen(TEST_MESSAGE_1) + 1);
    message_size = zipc_1536_64_receive(&receiver, &message);
    assert(message != NULL);
    assert(strcmp((char *)message, TEST_MESSAGE_1) == 0);
    message = NULL;

    zipc_1536_64_send(&sender, (const uint8_t *)TEST_MESSAGE_2, strlen(TEST_MESSAGE_2) + 1);
    message_size = zipc_1536_64_receive(&receiver, &message);
    assert(message != NULL);
    assert(message_size == strlen(TEST_MESSAGE_2) + 1);
    message = NULL;


    zipc_1536_64_send(&sender, (const uint8_t *)TEST_MESSAGE_3, strlen(TEST_MESSAGE_3) + 1);
    message_size = zipc_1536_64_receive(&receiver, &message);
    assert(message != NULL);
    assert(message_size == strlen(TEST_MESSAGE_3) + 1);
    message = NULL;
    printf("test function done\n");
}
