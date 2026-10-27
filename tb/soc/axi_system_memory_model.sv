// Module: axi_system_memory_model
// Description: Byte-addressed AXI verification RAM with deterministic channel stalls and error injection.
module axi_system_memory_model #(
    parameter int BYTES = 65536,
    parameter logic [31:0] BASE = 32'h80000000,
    parameter int WORD_BYTES = 4
) (
    input logic clk, rst, stall,
    input axi_types_pkg::axi_req_t req,
    output axi_types_pkg::axi_rsp_t rsp,
    input logic [31:0] fault_read_addr, fault_write_addr
);
    timeunit 1ns;
    timeprecision 1ps;
    import axi_types_pkg::*;
    byte unsigned mem [BYTES];
    axi_a_t read_q, write_q;
    logic read_busy_q, write_busy_q, b_valid_q;
    axi_b_t b_q;
    logic [7:0] read_beat_q, write_beat_q;
    int cycle_q;
    logic [31:0] ra, wa;
    logic read_bad, write_bad;
    axi_resp_e write_error_q;
    logic [255:0] read_payload_q;
    function automatic logic [255:0] read_payload(input logic [31:0] addr);
        logic [255:0] value;
        value='0;
        for(int lane=0;lane<32;lane++)
            if((addr & ~32'd31)+32'(lane)>=BASE && (addr & ~32'd31)+32'(lane)-BASE<BYTES)
                value[lane*8+:8]=mem[(addr & ~32'd31)+32'(lane)-BASE];
        return value;
    endfunction
    assign ra = read_q.addr + (32'(read_beat_q) << read_q.size);
    assign wa = write_q.addr + (32'(write_beat_q) << write_q.size);
    assign read_bad = ra < BASE || 64'(ra)+(64'd1 << read_q.size) > 64'(BASE)+64'(BYTES) ||
                      ra == fault_read_addr;
    assign write_bad = wa < BASE || 64'(wa)+(64'd1 << write_q.size) > 64'(BASE)+64'(BYTES) ||
                       wa == fault_write_addr;
    // 返回载荷只取当前 owner；地址或数据反压期间不能随 stall 开关撤回 valid。
    always_comb begin
        rsp = '0;
        rsp.ar_ready = !rst && !stall && !read_busy_q && cycle_q % 5 != 0;
        rsp.aw_ready = !rst && !stall && !write_busy_q && !b_valid_q && cycle_q % 3 != 0;
        rsp.w_ready = !rst && !stall && write_busy_q && !b_valid_q && cycle_q % 4 != 0;
        rsp.r_valid = !rst && read_busy_q;
        rsp.r.id = read_q.id;
        rsp.r.last = read_beat_q == read_q.len;
        rsp.r.resp = read_bad ? AXI_SLVERR : AXI_OKAY;
        rsp.r.data = read_bad ? '0 : read_payload_q;
        rsp.b_valid = !rst && b_valid_q;
        rsp.b = b_q;
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            read_busy_q <= 0; write_busy_q <= 0; b_valid_q <= 0;
            read_beat_q <= 0; write_beat_q <= 0; cycle_q <= 0; write_error_q <= AXI_OKAY;
        end else begin
            cycle_q <= cycle_q + 1;
            if (req.ar_valid && rsp.ar_ready) begin read_q <= req.ar; read_busy_q <= 1; read_beat_q <= 0; read_payload_q <= read_payload(req.ar.addr); end
            if (rsp.r_valid && req.r_ready) begin
                read_beat_q <= read_beat_q + 1'b1;
                read_payload_q <= read_payload(ra + (32'd1 << read_q.size));
                if (rsp.r.last) read_busy_q <= 0;
            end
            if (req.aw_valid && rsp.aw_ready) begin
                write_q <= req.aw; write_busy_q <= 1; write_beat_q <= 0; write_error_q <= AXI_OKAY;
            end
            if (req.w_valid && rsp.w_ready) begin
                if (!write_bad) begin
                    for (int lane = 0; lane < 32; lane++) begin
                        if (req.w.strb[lane] && (wa & ~32'd31) + 32'(lane) >= BASE &&
                            (wa & ~32'd31) + 32'(lane) - BASE < BYTES)
                            mem[(wa & ~32'd31) + 32'(lane) - BASE] <= req.w.data[lane*8 +: 8];
                    end
                end
                if (write_bad || req.w.last != (write_beat_q == write_q.len)) write_error_q <= AXI_SLVERR;
                write_beat_q <= write_beat_q + 1'b1;
                if (write_beat_q == write_q.len) begin
                    write_busy_q <= 0; b_valid_q <= 1;
                    b_q <= '{id:write_q.id, resp:write_bad || !req.w.last ? AXI_SLVERR : write_error_q};
                end
            end
            if (rsp.b_valid && req.b_ready) b_valid_q <= 0;
        end
    end
    // 预装 DDR 代码镜像：mem 按字节寻址，镜像按 XLEN 宽度逐字加载。
    task automatic load_image(input string path);
        localparam int unsigned WORDS = BYTES / WORD_BYTES;
        logic [WORD_BYTES*8-1:0] words [WORDS];
        for (int i = 0; i < WORDS; i++) words[i] = '0;
        $readmemh(path, words);
        for (int i = 0; i < WORDS; i++)
            for (int b = 0; b < WORD_BYTES; b++)
                mem[i*WORD_BYTES + b] = words[i][8*b +: 8];
    endtask
endmodule
