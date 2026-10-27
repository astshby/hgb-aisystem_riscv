/* RV32I/RV64I compiler ABI helpers implemented only with base-integer operations. */

static unsigned int udivmod32(unsigned int dividend,
                              unsigned int divisor,
                              unsigned int *remainder)
{
    unsigned int quotient = 0;
    unsigned int partial = 0;
    unsigned int bit;

    if (divisor == 0)
    {
        if (remainder != 0)
            *remainder = dividend;
        return ~0u;
    }
    for (bit = 0; bit < 32; bit++)
    {
        partial = (partial << 1) | (dividend >> 31);
        dividend <<= 1;
        quotient <<= 1;
        if (partial >= divisor)
        {
            partial -= divisor;
            quotient |= 1u;
        }
    }
    if (remainder != 0)
        *remainder = partial;
    return quotient;
}

static unsigned long long udivmod64(unsigned long long dividend,
                                    unsigned long long divisor,
                                    unsigned long long *remainder)
{
    unsigned long long quotient = 0;
    unsigned long long partial = 0;
    unsigned int bit;

    if (divisor == 0)
    {
        if (remainder != 0)
            *remainder = dividend;
        return ~0ull;
    }
    for (bit = 0; bit < 64; bit++)
    {
        partial = (partial << 1) | (dividend >> 63);
        dividend <<= 1;
        quotient <<= 1;
        if (partial >= divisor)
        {
            partial -= divisor;
            quotient |= 1ull;
        }
    }
    if (remainder != 0)
        *remainder = partial;
    return quotient;
}

unsigned int __mulsi3(unsigned int left, unsigned int right)
{
    unsigned int result = 0;

    while (right != 0)
    {
        if (right & 1u)
            result += left;
        left <<= 1;
        right >>= 1;
    }
    return result;
}

unsigned long long __muldi3(unsigned long long left, unsigned long long right)
{
    unsigned long long result = 0;

    while (right != 0)
    {
        if (right & 1ull)
            result += left;
        left <<= 1;
        right >>= 1;
    }
    return result;
}

unsigned int __udivsi3(unsigned int dividend, unsigned int divisor)
{
    return udivmod32(dividend, divisor, 0);
}

unsigned int __umodsi3(unsigned int dividend, unsigned int divisor)
{
    unsigned int remainder;

    udivmod32(dividend, divisor, &remainder);
    return remainder;
}

int __divsi3(int dividend, int divisor)
{
    unsigned int left = (dividend < 0) ? 0u - (unsigned int)dividend
                                       : (unsigned int)dividend;
    unsigned int right = (divisor < 0) ? 0u - (unsigned int)divisor
                                       : (unsigned int)divisor;
    unsigned int quotient = udivmod32(left, right, 0);

    return ((dividend < 0) != (divisor < 0)) ? (int)(0u - quotient)
                                             : (int)quotient;
}

int __modsi3(int dividend, int divisor)
{
    unsigned int left = (dividend < 0) ? 0u - (unsigned int)dividend
                                       : (unsigned int)dividend;
    unsigned int right = (divisor < 0) ? 0u - (unsigned int)divisor
                                       : (unsigned int)divisor;
    unsigned int remainder;

    udivmod32(left, right, &remainder);
    return (dividend < 0) ? (int)(0u - remainder) : (int)remainder;
}

unsigned long long __udivdi3(unsigned long long dividend,
                             unsigned long long divisor)
{
    return udivmod64(dividend, divisor, 0);
}

unsigned long long __umoddi3(unsigned long long dividend,
                             unsigned long long divisor)
{
    unsigned long long remainder;

    udivmod64(dividend, divisor, &remainder);
    return remainder;
}

long long __divdi3(long long dividend, long long divisor)
{
    unsigned long long left = (dividend < 0)
                                  ? 0ull - (unsigned long long)dividend
                                  : (unsigned long long)dividend;
    unsigned long long right = (divisor < 0)
                                   ? 0ull - (unsigned long long)divisor
                                   : (unsigned long long)divisor;
    unsigned long long quotient = udivmod64(left, right, 0);

    return ((dividend < 0) != (divisor < 0))
               ? (long long)(0ull - quotient)
               : (long long)quotient;
}

long long __moddi3(long long dividend, long long divisor)
{
    unsigned long long left = (dividend < 0)
                                  ? 0ull - (unsigned long long)dividend
                                  : (unsigned long long)dividend;
    unsigned long long right = (divisor < 0)
                                   ? 0ull - (unsigned long long)divisor
                                   : (unsigned long long)divisor;
    unsigned long long remainder;

    udivmod64(left, right, &remainder);
    return (dividend < 0) ? (long long)(0ull - remainder)
                          : (long long)remainder;
}
