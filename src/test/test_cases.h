#ifndef TEST_CASES_H
#define TEST_CASES_H

#include "./test_case.h"

#include "./test_single_thread_lock_step.h"
#include "./test_separate_threads.h"

static TestCase test_cases[] = {
    {"single_thread_lock_step", test_single_thread_lock_step},
    {"separate_threads", test_separate_threads},
};

#endif // TEST_CASES_H
