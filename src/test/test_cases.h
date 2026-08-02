#ifndef TEST_CASES_H
#define TEST_CASES_H

#include "./test_case.h"

#include "./test_single_thread_lock_step.h"
#include "./test_separate_threads.h"
#include "./test_full_queue.h"

static TestCase test_cases[] = {
    {"single_thread_lock_step", test_single_thread_lock_step},
    {"separate_threads", test_separate_threads},
    {"full_queue", test_full_queue},
};

#endif // TEST_CASES_H
