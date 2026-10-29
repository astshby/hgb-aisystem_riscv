/* Module: rt_demo_command
 * Description: Bounded line reception shared by the UART application and C tests.
 */
#ifndef HGB_RT_DEMO_COMMAND_H
#define HGB_RT_DEMO_COMMAND_H
#include <stddef.h>
enum rt_demo_command { DEMO_MORE, DEMO_STATUS, DEMO_PING, DEMO_ECHO, DEMO_TASKS, DEMO_BAD, DEMO_LONG };
struct rt_demo_input {
    char text[128];
    size_t length;
    unsigned swallow_lf, overflow;
};
enum rt_demo_command rt_demo_feed(struct rt_demo_input *input, unsigned char byte);
#endif
