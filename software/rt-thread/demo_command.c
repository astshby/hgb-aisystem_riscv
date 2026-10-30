/* Module: rt_demo_command
 * Description: CRLF-aware terminal commands without allocation or shared device state.
 */
#include "demo_command.h"

static int equal(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

enum rt_demo_command rt_demo_feed(struct rt_demo_input *input, unsigned char byte)
{
    if (input->swallow_lf && byte == '\n') {
        input->swallow_lf = 0;
        return DEMO_MORE;
    }
    input->swallow_lf = 0;
    if (byte != '\r' && byte != '\n') {
        if (byte == 0 || input->length == sizeof(input->text) - 1) input->overflow = 1;
        else if (!input->overflow) input->text[input->length++] = (char)byte;
        return DEMO_MORE;
    }
    input->swallow_lf = byte == '\r';
    input->text[input->length] = 0;
    input->length = 0;
    if (input->overflow) {
        input->overflow = 0;
        return DEMO_LONG;
    }
    if (!input->text[0] || equal(input->text, "STATUS")) return DEMO_STATUS;
    if (equal(input->text, "PING")) return DEMO_PING;
    if (equal(input->text, "DEMO")) return DEMO_TASKS;
    const char *prefix = "ECHO ";
    unsigned index = 0;
    while (prefix[index] && input->text[index] == prefix[index]) index++;
    if (!prefix[index]) return DEMO_ECHO;
    return DEMO_BAD;
}
