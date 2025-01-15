#include <iostream>
#include <chrono>
#include <thread>
#include "zipc.h"

int main() {
    // Create a receiver
    ZipcContext receiver = zipc_1536_64_create_receiver("/my-zipc-path");
    
    // Receive data
    uint8_t *received_msg = nullptr;
    
    while(true)  {
        uint32_t rres = zipc_1536_64_receive(&receiver, &received_msg);
        if (rres > 0) {
            std::cout << "Received message with length: " << rres << std::endl;
        } else {
            // sleep 2ms
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }
    }
    
    // Clean up
    // zipc_unlink("/my-zipc-path");

    return 0;
}