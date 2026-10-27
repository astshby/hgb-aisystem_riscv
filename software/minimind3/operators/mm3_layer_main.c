/* Module: mm3_layer_main
 * Description: Real RISC-V CPU dispatches a prevalidated one-token operator program through MMIO.
 */
#include "mm3_ops.h"
#include "benchmark_runtime.h"
int main(void){
 const volatile uint32_t *control=(const volatile uint32_t *)(uintptr_t)0x80400100u;
 if(control[0]!=0x4d334f50u||control[1]==0||control[1]>MM3_MAX_COMMANDS)return 2;
 const MM3Command *commands=(const MM3Command *)(uintptr_t)control[2];
 MM3Backend hardware={mm3_mmio_submit,NULL};uint64_t start=benchmark_read_cycle();
 int rc=mm3_run_program(&hardware,commands,control[1]);
 if(rc){fprintf(stderr,"MM3 operator error %d\n",rc);return 3;}
 fprintf(stdout,"MM3_LAYER_PROGRAM_PASS commands=%u cycles=%llu\n",control[1],(unsigned long long)(benchmark_read_cycle()-start));
 return 0;
}
