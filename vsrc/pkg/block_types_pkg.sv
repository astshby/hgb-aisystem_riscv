// Package: block_types_pkg
// Description: Bounded DDR block commands, 256-bit beats and independent read/write completion channels.
package block_types_pkg;
    import core_types_pkg::*;
    import bus_types_pkg::*;

    localparam int unsigned BLOCK_MAX_BEATS = 4;
    localparam int unsigned BLOCK_MAX_BYTES = BLOCK_MAX_BEATS * DDR_BEAT_BYTES;
    // len为beat数减一；size是每beat的逻辑访问宽度，窄单拍沿用原地址/lane，不扩大权限。
    // 每client每方向最多一笔，仲裁器保存client owner；读写方向可独立在途，W不得交织。
    typedef struct packed {
        xlen_t addr;
        logic [7:0] len;
        logic [2:0] size;
        logic execute;
    } block_cmd_t;
    typedef struct packed {
        logic [DDR_DATA_W-1:0] data;
        logic [DDR_BEAT_BYTES-1:0] strb;
        logic last;
    } block_w_t;
    typedef struct packed {
        logic [DDR_DATA_W-1:0] data;
        bus_error_e error;
        logic last;
    } block_r_t;
    typedef struct packed {
        bus_error_e error;
    } block_b_t;
endpackage
