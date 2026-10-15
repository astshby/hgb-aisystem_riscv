/* SPDX-License-Identifier: Apache-2.0 */
#include "protocol.h"
uint32_t hgb_crc(uint32_t crc, uint8_t value)
{
    crc ^= value;
    for (unsigned i=0; i<8; i++)
        crc=(crc>>1)^((0u-(crc&1u))&0xedb88320u);
    return crc;
}
static int word(uint32_t *value, uint32_t *crc)
{
    *value=0;
    for (unsigned i=0; i<4; i++) {
        uint8_t byte;
        int error=loader_get(&byte);
        if (error) return error;
        *value |= (uint32_t)byte << (8*i);
        if (crc) *crc=hgb_crc(*crc, byte);
    }
    return HGB_OK;
}
int hgb_receive(uint32_t config, uint32_t *entry)
{
    struct hgb_segment segments[HGB_SEGMENTS];
    uint32_t header[7], crc=~0u, table_crc=~0u;
    *entry=0;
    for (unsigned i=0; i<7; i++) {
        int error=word(&header[i], i<6 ? &crc : 0);
        if (error) return error;
    }
    if (header[0]!=0x31424748u || header[1]!=1 || header[6]!=~crc ||
        !header[4] || header[4]>HGB_SEGMENTS) return HGB_HEADER;
    if (header[2]!=config) return HGB_CONFIG_ERROR;
    unsigned executable_entry=0;
    for (unsigned i=0; i<header[4]; i++) {
        uint32_t *fields[]={&segments[i].address,&segments[i].size,&segments[i].flags,&segments[i].crc};
        for (unsigned j=0; j<4; j++) {
            int error=word(fields[j], &table_crc);
            if (error) return error;
        }
        uint32_t a=segments[i].address, n=segments[i].size;
        /* 减法边界检查避免整数回绕；loader、栈与 scratch 不可下载覆盖。 */
        unsigned ddr=a>=0x80000000u && a<0x80020000u && n<=0x80020000u-a;
        unsigned hot=a>=0x0110c000u && a<0x0110e000u && n<=0x0110e000u-a;
        if (!n || (!ddr && !hot) || (segments[i].flags&~1u) ||
            (hot && segments[i].flags)) return HGB_RANGE;
        for (unsigned j=0; j<i; j++)
            if (a<segments[j].address+segments[j].size && segments[j].address<a+n)
                return HGB_OVERLAP;
        if (ddr && segments[i].flags && !(header[3]&3u) &&
            header[3]>=a && header[3]-a<n) executable_entry=1;
    }
    if (~table_crc!=header[5]) return HGB_CRC;
    if (!executable_entry) return HGB_RANGE;
    loader_put(0x06);
    for (unsigned i=0; i<header[4]; i++) {
        uint32_t segment_crc=~0u;
        for (uint32_t offset=0; offset<segments[i].size;) {
            uint32_t block_crc=~0u, expected;
            unsigned count=segments[i].size-offset;
            if (count>HGB_BLOCK) count=HGB_BLOCK;
            for (unsigned j=0; j<count; j++) {
                uint8_t byte;
                int error=loader_get(&byte);
                if (error) return error;
                block_crc=hgb_crc(block_crc, byte);
                segment_crc=hgb_crc(segment_crc, byte);
                loader_store(segments[i].address+offset+j, byte);
            }
            int error=word(&expected, 0);
            if (error) return error;
            if (~block_crc!=expected) return HGB_CRC;
            offset+=count;
            loader_put(0x06);
        }
        if (~segment_crc!=segments[i].crc) return HGB_CRC;
    }
    /* flush/invalidate 后逐段读回，不能把 UART 接收完成视为 DDR 已发布。 */
    if (loader_flush()) return HGB_CACHE;
    for (unsigned i=0; i<header[4]; i++) {
        crc=~0u;
        for (uint32_t j=0; j<segments[i].size; j++)
            crc=hgb_crc(crc, loader_load(segments[i].address+j));
        if (~crc!=segments[i].crc) return HGB_READBACK;
    }
    *entry=header[3];
    return HGB_OK;
}
