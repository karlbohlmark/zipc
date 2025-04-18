#include <stdio.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <assert.h>

#include "zipc.h"
#include "zipc_test_config.h"
#include "./test_separate_threads.h"

#define ZipcSender ZipcContext
#define ZipcReceiver ZipcContext

#define TEST_MESSAGE_1 "hello"
#define TEST_MESSAGE_2 "world"
#define TEST_MESSAGE_3 "!"

#define QUEUE_SIZE 64
#define MESSAGE_SIZE 1024


char* receive_next_message(ZipcReceiver *receiver, uint8_t **message) {
    int message_size = zipc_receive(receiver, message);
    int sleep_duration_millis = 20;
    while(message_size == 0) {
        usleep(sleep_duration_millis * 1000);
        message_size = zipc_receive(receiver, message);
    }

    
    char *return_value = strdup((char *)message);
    return return_value;
}

void* client_thread(void* arg) {
    ZipcReceiver receiver = zipc_create_receiver("/testar", QUEUE_SIZE, MESSAGE_SIZE);
    uint8_t *message = NULL;
    receive_next_message(&receiver, &message);
    printf("Received message 1: %s\n", (char *)message);
    if (strcmp((char *)message, TEST_MESSAGE_1) != 0) {
        perror("Received message 1 is not equal to TEST_MESSAGE_1");
        exit(EXIT_FAILURE);
    }
    receive_next_message(&receiver, &message);
    printf("Received message 2: %s\n", (char *)message);
    if (strcmp((char *)message, TEST_MESSAGE_2) != 0) {
        perror("Received message 2 is not equal to TEST_MESSAGE_2");
        exit(EXIT_FAILURE);
    }
    receive_next_message(&receiver, &message);
    printf("Received message 3: %s\n", (char *)message);
    if (strcmp((char *)message, TEST_MESSAGE_3) != 0) {
        perror("Received message 3 is not equal to TEST_MESSAGE_3");
        exit(EXIT_FAILURE);
    }
    return NULL;
}

void test_separate_threads() {
    pthread_t thread;
    if (pthread_create(&thread, NULL, client_thread, NULL) != 0) {
        perror("Failed to create thread");
        exit(EXIT_FAILURE);
    }
    ZipcSender sender = zipc_create_sender("/testar", QUEUE_SIZE, MESSAGE_SIZE);

    zipc_send(&sender, (const uint8_t *)TEST_MESSAGE_1, strlen(TEST_MESSAGE_1) + 1);
    zipc_send(&sender, (const uint8_t *)TEST_MESSAGE_2, strlen(TEST_MESSAGE_2) + 1);
    zipc_send(&sender, (const uint8_t *)TEST_MESSAGE_3, strlen(TEST_MESSAGE_3) + 1);

    if (pthread_join(thread, NULL) != 0) {
        perror("Failed to join thread");
        exit(EXIT_FAILURE);
    }

    printf("All tests passed!\n");
    return;
}