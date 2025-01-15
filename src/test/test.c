#include <stdio.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <assert.h>

#include "zipc.h"
#include "./test_cases.h"

#define EXIT_FAILURE 1

// Function to find and execute a test case
void run_test(const char* test_name) {
    size_t num_tests = sizeof(test_cases) / sizeof(TestCase);

    for (size_t i = 0; i < num_tests; i++) {
        if (strcmp(test_cases[i].name, test_name) == 0) {
            printf("------------------------------------------------------------\n");
            printf("           | Executing '%s' |           \n", test_name);
            printf("------------------------------------------------------------\n");
            test_cases[i].func();
            printf("Did run test\n");
            printf("%s passed!\n", test_name);
            return;
        }
    }

    printf("Test case '%s' not found!\n", test_name);
}

int main(int argc, char* argv[]) {
    if (argc != 2) {
        // run_test(test_cases[0].name);
        // return 0;
        int test_index = 0;
        int num_test_cases = sizeof(test_cases) / sizeof(TestCase);
        while (test_index < num_test_cases) {
            TestCase test_case = test_cases[test_index];
            run_test(test_case.name);
            test_index++;
        }
        return 0;
    }

    const char* test_name = argv[1];
    run_test(test_name);
    return 0;
}