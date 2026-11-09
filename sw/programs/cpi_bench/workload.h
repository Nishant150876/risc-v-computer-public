// Shared Phase 5 CPI workload, used by cpi_bench (simulation, checked
// checksum) and cpi_report (board, prints the hardware counters).
// fib: dependent ALU chain and a loop branch; sum: loads with immediate use;
// sort: data-dependent branches, loads and stores; calls: JAL/JALR and the
// stack; copy: load/store streaming.
#ifndef CPI_WORKLOAD_H
#define CPI_WORKLOAD_H

#include <stdint.h>

#define N 64

static volatile uint32_t data[N];
static uint32_t copy[N];

static uint32_t fib(uint32_t n) {
    uint32_t a = 0, b = 1;
    while (n-- != 0) {
        uint32_t t = a + b;
        a = b;
        b = t;
    }
    return a;
}

static uint32_t depth(uint32_t n) {
    return n == 0 ? 0 : 1 + depth(n - 1);
}

/* Returns the checksum; *sorted_ok is 0 if the sort check failed. */
static uint32_t cpi_workload(uint32_t *sorted_ok) {
    uint32_t seed = 12345, checksum = 0;
    for (int round = 0; round < 8; ++round) checksum += fib(30 + round);
    for (int i = 0; i < N; ++i) {
        seed = seed * 1103515245u + 12345u;
        data[i] = seed >> 16;
    }
    for (int r = 0; r < 4; ++r)
        for (int i = 0; i < N; ++i) checksum += data[i];
    for (int i = 0; i < N; ++i)
        for (int j = 0; j + 1 < N - i; ++j)
            if (data[j] > data[j + 1]) {
                uint32_t t = data[j];
                data[j] = data[j + 1];
                data[j + 1] = t;
            }
    uint32_t bad = 0;
    for (int i = 0; i + 1 < N; ++i) bad |= data[i] > data[i + 1];
    for (int r = 0; r < 16; ++r) checksum += depth(20 + r);
    for (int r = 0; r < 4; ++r)
        for (int i = 0; i < N; ++i) copy[i] = data[i] ^ (uint32_t)r;
    for (int i = 0; i < N; ++i) checksum += copy[i] * (uint32_t)(i + 1);
    *sorted_ok = bad == 0;
    return checksum;
}

#endif
