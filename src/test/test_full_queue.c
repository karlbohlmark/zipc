#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

#include "zipc.h"
#include "zipc_test_config.h"
#include "./test_full_queue.h"

#define ZipcSender ZipcContext
#define ZipcReceiver ZipcContext

/* Small on purpose: capacity is QUEUE_SIZE - 1, so three sends fill it. */
#define QUEUE_SIZE 4
#define MESSAGE_SIZE 16

static void fail(const char *what) {
    fprintf(stderr, "test_full_queue: %s\n", what);
    exit(EXIT_FAILURE);
}

/* A send that the queue rejects must not touch shared memory. When the queue
   is full the next slot to be written is exactly the one the consumer was most
   recently handed by zipc_receive, so a rejected send used to overwrite a
   message that had already been delivered. */
static void rejected_send_does_not_clobber_delivered_message(void) {
    zipc_unlink("/zipc-test-full");
    ZipcSender sender = zipc_create_sender("/zipc-test-full", QUEUE_SIZE, MESSAGE_SIZE);
    ZipcReceiver receiver = zipc_create_receiver("/zipc-test-full", QUEUE_SIZE, MESSAGE_SIZE);

    if (!zipc_send(&sender, (const uint8_t *)"MSG-0", 6)) fail("first send rejected");
    if (!zipc_send(&sender, (const uint8_t *)"MSG-1", 6)) fail("second send rejected");
    if (!zipc_send(&sender, (const uint8_t *)"MSG-2", 6)) fail("third send rejected");

    uint8_t *held = NULL;
    if (zipc_receive(&receiver, &held) != 6) fail("expected to receive MSG-0");
    if (strcmp((char *)held, "MSG-0") != 0) fail("wrong message delivered");

    /* Fits: tail wraps onto the slot the consumer is holding, but head has not
       moved, so the queue is now full. */
    if (!zipc_send(&sender, (const uint8_t *)"MSG-3", 6)) fail("fourth send rejected");

    if (zipc_send(&sender, (const uint8_t *)"OVERLOAD", 9)) fail("send into a full queue reported success");
    if (strcmp((char *)held, "MSG-0") != 0)
        fail("rejected send overwrote the message the consumer was holding");

    /* The channel must still work once the consumer drains. */
    uint8_t *next = NULL;
    if (zipc_receive(&receiver, &next) != 6) fail("expected to receive MSG-1");
    if (!zipc_send(&sender, (const uint8_t *)"AFTER", 6)) fail("send after a rejection failed");

    zipc_unlink("/zipc-test-full");
}

/* A message larger than the channel's message_size must be rejected before it
   is copied; slots have no redzone and the last one is followed by the init
   flag and then the end of the mapping. */
static void oversized_send_is_rejected(void) {
    zipc_unlink("/zipc-test-oversize");
    ZipcSender sender = zipc_create_sender("/zipc-test-oversize", QUEUE_SIZE, MESSAGE_SIZE);
    ZipcReceiver receiver = zipc_create_receiver("/zipc-test-oversize", QUEUE_SIZE, MESSAGE_SIZE);

    const int32_t init_flag_before = *sender.init_flag;

    /* Walk the tail to the last slot so an overrun would run off the end of
       the buffer region rather than into a neighbouring slot. */
    for (int i = 0; i < QUEUE_SIZE - 1; i++) {
        if (!zipc_send(&sender, (const uint8_t *)"x", 2)) fail("setup send rejected");
        uint8_t *drain = NULL;
        zipc_receive(&receiver, &drain);
    }

    char big[MESSAGE_SIZE * 4];
    memset(big, 'X', sizeof big);
    if (zipc_send(&sender, (const uint8_t *)big, sizeof big)) fail("oversized send reported success");
    if (*sender.init_flag != init_flag_before) fail("oversized send overwrote the init flag");

    /* Exactly message_size must still be accepted. */
    char exact[MESSAGE_SIZE];
    memset(exact, 'e', sizeof exact);
    if (!zipc_send(&sender, (const uint8_t *)exact, sizeof exact)) fail("send of exactly message_size rejected");
    uint8_t *m = NULL;
    if (zipc_receive(&receiver, &m) != MESSAGE_SIZE) fail("wrong length for a full-size message");
    if (memcmp(m, exact, MESSAGE_SIZE) != 0) fail("full-size message came back corrupted");

    zipc_unlink("/zipc-test-oversize");
}

void test_full_queue() {
    rejected_send_does_not_clobber_delivered_message();
    oversized_send_is_rejected();
}
