#include <iostream>
#include <chrono>
#include <thread>
#include "zipc.h"

#define TEST_MESSAGE "hello"
#define QUEUE_SIZE 64
#define MESSAGE_SIZE 1024

int main() {
    // Create a sender
    ZipcContext sender = zipc_create_sender("/my-zipc-path", QUEUE_SIZE, MESSAGE_SIZE);
    
    while(true)  {
        zipc_send(&sender, (const uint8_t *)TEST_MESSAGE, strlen(TEST_MESSAGE) + 1);
        std::this_thread::sleep_for(std::chrono::milliseconds(210));
    }
    
    // Clean up
    // zipc_unlink("/my-zipc-path");

    return 0;
}