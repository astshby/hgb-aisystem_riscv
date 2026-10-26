// Module: npu_background
// Description: Resident four-pixel NPU jobs serviced by the existing timer while DDR DMA runs independently.
#define NPU_REG(offset) REG(0x20000000u + (offset))
static uint32_t npu_tasks CONTROL, npu_vectors CONTROL, npu_pixel CONTROL, npu_running CONTROL;
static uint32_t npu_roi_tasks CONTROL, npu_roi_vectors CONTROL;

static TCM_FN int npu_expected(unsigned pixel, unsigned oc)
{
    int value = (int)oc;
    for (unsigned ic = 0; ic < 8; ic++)
        value += ((int)pixel + (int)ic - 4) * ((int)((oc + ic) % 5) - 2);
    return value;
}

static TCM_FN void npu_prepare(void)
{
    if (NPU_REG(0) != 0x4e505531 || NPU_REG(4) != 0x00010000) fail(90);
    NPU_REG(8) = 2;
    for (unsigned word = 0; word < 32; word++) {
        uint32_t data = 0;
        for (unsigned b = 0; b < 4; b++) {
            unsigned index = word * 4 + b;
            data |= (uint32_t)(uint8_t)((int)((index / 8 + index % 8) % 5) - 2) << (b * 8);
        }
        NPU_REG(0x100 + word * 4) = data;
    }
    NPU_REG(0x2c) = 0;
    NPU_REG(0x3c) = 1;
    for (unsigned p = 0; p < 4; p++) {
        NPU_REG(0x28) = p;
        for (unsigned half = 0; half < 2; half++) {
            uint32_t data = 0;
            for (unsigned b = 0; b < 4; b++)
                data |= (uint32_t)(uint8_t)((int)(p + half * 4 + b) - 4) << (8 * b);
            NPU_REG(0x60 + half * 4) = data;
        }
        NPU_REG(0x38) = 1;
    }
    for (unsigned oc = 0; oc < 16; oc++) NPU_REG(0x80 + oc * 4) = oc;
    NPU_REG(0x20) = 4u | (1u << 8) | (8u << 16);
    NPU_REG(0x24) = 16;
    if (NPU_REG(0x10)) fail(91);
}

static TCM_FN void npu_start(void)
{
    NPU_REG(8) = 1;
    npu_pixel = 0;
    npu_running = 1;
}

static TCM_FN void npu_collect(unsigned restart)
{
    unsigned status = NPU_REG(0x0c);
    if (status & 8) fail(92);
    if (!(status & 2)) return;
    unsigned meta = NPU_REG(0x58), flags = NPU_REG(0x5c);
    if ((meta & 65535) != 65535 || (meta >> 16) != npu_pixel ||
        !!(flags & 4) != (npu_pixel == 3)) fail(93);
    for (unsigned oc = 0; oc < 16; oc++)
        if ((int32_t)NPU_REG(0x200 + oc * 4) != npu_expected(npu_pixel, oc)) errors++;
    NPU_REG(0x44) = 1;
    npu_vectors++;
    npu_pixel++;
    if (flags & 4) {
        if ((NPU_REG(0x0c) & 5) != 4) fail(94);
        npu_tasks++;
        npu_running = 0;
        if (restart) npu_start();
    }
}
