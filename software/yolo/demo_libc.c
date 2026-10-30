/* Module: yolo_demo_libc
 * Description: Minimal freestanding ABI required by the graph parser and software-float libm.
 */
#include <stddef.h>

int memcmp(const void *left,const void *right,size_t bytes)
{
    const unsigned char *a=left,*b=right;
    for (size_t i=0;i<bytes;++i) if (a[i]!=b[i]) return (int)a[i]-(int)b[i];
    return 0;
}

int *__errno(void)
{
    // 此裸机应用只有一个执行者；libm 的范围/定义域错误使用本地 errno。
    static int math_errno;
    return &math_errno;
}
