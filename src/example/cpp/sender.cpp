#include <iostream>
#include <chrono>
#include <thread>
#include "zipc.h"

#define TEST_MESSAGE "hello"

int main() {
    // Create a sender
    ZipcContext sender = zipc_1536_64_create_sender("/my-zipc-path");
    
    while(true)  {
        zipc_1536_64_send(&sender, (const uint8_t *)TEST_MESSAGE, strlen(TEST_MESSAGE) + 1);
        std::this_thread::sleep_for(std::chrono::milliseconds(210));
    }
    
    // Clean up
    // zipc_unlink("/my-zipc-path");

    return 0;
}