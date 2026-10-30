/* Module: yolo_soft_clz
 * Description: Integer leading-zero helpers for software floating-point runtime.
 */
int __clzdi2(unsigned long long value)
{
    int count = 64;
    if (value >> 32) { value >>= 32; count -= 32; }
    if (value >> 16) { value >>= 16; count -= 16; }
    if (value >> 8) { value >>= 8; count -= 8; }
    if (value >> 4) { value >>= 4; count -= 4; }
    if (value >> 2) { value >>= 2; count -= 2; }
    if (value >> 1) { value >>= 1; count -= 1; }
    return count - (int)value;
}

int __clzsi2(unsigned int value)
{
    return __clzdi2(value) - 32;
}
