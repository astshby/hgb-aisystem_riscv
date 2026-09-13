#include "benchmark_runtime.h"

static volatile unsigned int initialized_word = 0x13579bdfu;
static volatile unsigned int zero_word;

static __attribute__((noinline)) unsigned int mix_values(unsigned int left,
                                                         unsigned int right)
{
    return (left * right) + (left / right) + (left % right);
}

int main(void)
{
    volatile unsigned int operands[4] = {37u, 29u, 97u, 0u};
    volatile unsigned long long wide = 0x0000000123456789ull;
    benchmark_cycle_t cycle_before;
    benchmark_cycle_t cycle_after;

    if (initialized_word != 0x13579bdfu)
        return 1;
    if (zero_word != 0)
        return 2;
    if (mix_values(operands[0], operands[1]) != 1082u)
        return 3;
    if ((wide / operands[2]) != 0x000000000300b72bull)
        return 4;
    if ((wide % operands[2]) != 62ull)
        return 5;

    operands[3] = operands[0] + operands[1] + operands[2];
    if (operands[3] != 163u)
        return 6;

    cycle_before = benchmark_read_cycle();
    cycle_after = benchmark_read_cycle();
    if (cycle_after <= cycle_before)
        return 7;
    return 0;
}
