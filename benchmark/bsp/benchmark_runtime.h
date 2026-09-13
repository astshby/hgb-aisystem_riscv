#ifndef RHBYV_BENCHMARK_RUNTIME_H
#define RHBYV_BENCHMARK_RUNTIME_H

typedef unsigned long long benchmark_cycle_t;

benchmark_cycle_t benchmark_read_cycle(void);
void benchmark_putchar(char value);

#endif
