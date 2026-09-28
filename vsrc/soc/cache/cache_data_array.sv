// Module: cache_data_array
// Description: Two independent synchronous-read byte-writable RAM ways without data reset.
module cache_data_array #(
    parameter int unsigned CACHE_BYTES = 4096,
    parameter int unsigned WORD_BYTES = 4,
    parameter int unsigned ADDR_W = $clog2(CACHE_BYTES / (2 * WORD_BYTES))
) (
    input logic clk,
    input logic read_enable,
    input logic [ADDR_W-1:0] read_addr,
    output logic [WORD_BYTES*8-1:0] read_data [2],
    input logic write_enable, write_way,
    input logic [ADDR_W-1:0] write_addr,
    input logic [WORD_BYTES*8-1:0] write_data,
    input logic [WORD_BYTES-1:0] write_mask
);
    // 控制器将查找与填行分开，避免依赖厂商的同地址读写碰撞语义。
    // 仅复位元数据 valid；不复位数据 RAM，以保留同步 BRAM 推断可能性。
    for (genvar way = 0; way < 2; way++) begin : g_way
        logic [WORD_BYTES*8-1:0] words [CACHE_BYTES/(2*WORD_BYTES)];
        always_ff @(posedge clk) begin
            if (read_enable) read_data[way] <= words[read_addr];
            if (write_enable && write_way == 1'(way))
                for (int b = 0; b < WORD_BYTES; b++)
                    if (write_mask[b]) words[write_addr][8*b +: 8] <= write_data[8*b +: 8];
        end
    end
endmodule
