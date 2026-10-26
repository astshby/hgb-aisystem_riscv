/* Module: fixed_reference
 * Description: Independent fixture generator using the unchanged integer C reference.
 */
#include "integer.h"
#include <inttypes.h>
#include <stdio.h>
static uint64_t seed=UINT64_C(0x4d4d330123456789);
static uint64_t random64(void){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return seed;}
int main(void){
    for(unsigned i=0;i<800;i++){
        int64_t av=(int64_t)random64(),bv=(int64_t)random64();
        if(i<16){av=(int64_t[]){0,1,-1,32767,-32767,INT64_MAX,INT64_MIN,2}[i%8];bv=(int64_t[]){0,1,-1,3,7,32767,INT64_MAX,INT64_MIN}[i%8];}
        IFixed a=if_make(av,(int)(random64()%1200)-600),b=if_make(bv,(int)(random64()%1200)-600);
        if(i>=16&&i<24){a=(IFixed){(INT64_C(1)<<60)+(int64_t)(i%4)*2+1,-60};if(i>=20)a.v=-a.v;b=(IFixed){INT64_C(3)<<59,-60};}
        if(i>=24&&i<32){a=if_make(i<28?5+(int64_t)(i%2)*2:-5-(int64_t)(i%2)*2,-1);b=if_make(1,0);}
        for(unsigned op=0;op<2;op++){
            IFixed r=op?if_div(a,b):if_mul(a,b);
            IStats s16={0},s32={0};int64_t q16=if_integer(r,16,&s16),q32=if_integer(r,32,&s32);
            unsigned flags=(unsigned)s16.saturated|((unsigned)s16.underflow<<1)|((unsigned)s32.saturated<<2)|((unsigned)s32.underflow<<3);
            printf("%u %016" PRIx64 " %08" PRIx32 " %016" PRIx64 " %08" PRIx32 " %016" PRIx64 " %08" PRIx32 " %08" PRIx32 " %08" PRIx32 " %x\n",op,(uint64_t)a.v,(uint32_t)a.e,(uint64_t)b.v,(uint32_t)b.e,(uint64_t)r.v,(uint32_t)r.e,(uint32_t)q16,(uint32_t)q32,flags);
        }
    }
    return 0;
}
