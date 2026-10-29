/* Module: yolo_softmath_check
 * Description: Execute required IEEE arithmetic and libm operations on the integer-only RISC-V core.
 */
#include <stdint.h>
#include <math.h>
#include "benchmark_runtime.h"

static float from_bits(uint32_t bits) { union {uint32_t u;float f;} value={.u=bits}; return value.f; }
static uint32_t bits(float number) { union {uint32_t u;float f;} value={.f=number}; return value.u; }
static int near(float number,uint32_t expected) {
    uint32_t actual=bits(number);
    return actual==expected || actual+1==expected || actual==expected+1;
}

int main(void)
{
    volatile float a=1.5f,b=2.25f,c=-1.25f;
    if (bits(a+b)!=0x40700000u) return 1;
    if (bits(a-b)!=0xbf400000u) return 2;
    if (bits(a*b)!=0x40580000u) return 3;
    a=1.0f;b=3.0f;
    if (bits(a/b)!=0x3eaaaaabu) return 4;
    a=from_bits(1);b=from_bits(1);
    if (bits(a+b)!=2u) return 5;
    a=from_bits(0x80000000u);
    if (bits(fabsf(a))) return 6;
    if (bits(floorf(c))!=0xc0000000u) return 7;
    if (bits(sqrtf(4.0f))!=0x40000000u) return 8;
    a=2.0f;
    if (!near(sqrtf(a),0x3fb504f3u)) return 9;
    a=0.0f;
    if (bits(expf(a))!=0x3f800000u) return 10;
    a=1.0f;
    if (!near(expf(a),0x402df854u)) return 11;
    a=from_bits(0x7fc00000u);b=3.0f;
    if (a==a || !(a!=a) || bits(fmaxf(a,b))!=0x40400000u) return 12;
    if (bits(fminf(c,a))!=0xbfa00000u) return 13;
    a=-1.0f;
    if (!isnan(sqrtf(a))) return 14;
    a=-3.75f;
    if ((int)a!=-3 || bits((float)(int)a)!=0xc0400000u) return 15;
    a=1.5f;b=3.0f;
    volatile double wide=(double)a/(double)b;
    if (bits((float)wide)!=0x3f000000u) return 16;
    if (bits((float)fmax((double)a,(double)b))!=0x40400000u) return 17;
    const char *text="PASS yolo softmath checks=17 integer-only core\n";
    while (*text) benchmark_putchar(*text++);
    return 0;
}
