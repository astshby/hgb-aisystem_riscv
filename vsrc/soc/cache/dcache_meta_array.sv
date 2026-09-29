// Module: dcache_meta_array
// Description: Two-way writeback tags, valid/dirty bits, probe port and one-bit LRU.
module dcache_meta_array #(
    parameter int SETS = 64,
    parameter int SET_W = $clog2(SETS),
    parameter int TAG_W = 21
) (
    input logic clk, rst,
    input logic [SET_W-1:0] lookup_set,
    input logic [TAG_W-1:0] lookup_tag,
    output logic hit, hit_way, victim_way,
    input logic probe_way,
    output logic probe_valid, probe_dirty,
    output logic [TAG_W-1:0] probe_tag,
    input logic invalidate_entry, install, touch, mark_dirty, mark_clean,
    input logic update_way,
    input logic [TAG_W-1:0] install_tag
);
    logic valid_q [SETS][2], dirty_q [SETS][2], lru_q [SETS];
    logic [TAG_W-1:0] tag_q [SETS][2];
    always_comb begin
        hit_way = valid_q[lookup_set][1] && tag_q[lookup_set][1] == lookup_tag;
        hit = hit_way || (valid_q[lookup_set][0] && tag_q[lookup_set][0] == lookup_tag);
        victim_way = !valid_q[lookup_set][0] ? 0 : !valid_q[lookup_set][1] ? 1 : lru_q[lookup_set];
        probe_valid = valid_q[lookup_set][probe_way];
        probe_dirty = probe_valid && dirty_q[lookup_set][probe_way];
        probe_tag = tag_q[lookup_set][probe_way];
    end
    // 写回失败时控制器不发 mark_clean/invalidate；脏数据必须继续留在原 way。
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int s = 0; s < SETS; s++) begin
                valid_q[s][0] <= 0; valid_q[s][1] <= 0;
                dirty_q[s][0] <= 0; dirty_q[s][1] <= 0;
                lru_q[s] <= 0;
            end
        end else begin
            if (invalidate_entry) begin valid_q[lookup_set][update_way] <= 0; dirty_q[lookup_set][update_way] <= 0; end
            if (install) begin
                valid_q[lookup_set][update_way] <= 1;
                dirty_q[lookup_set][update_way] <= 0;
                tag_q[lookup_set][update_way] <= install_tag;
            end
            if (mark_clean) dirty_q[lookup_set][update_way] <= 0;
            if (mark_dirty) dirty_q[lookup_set][update_way] <= 1;
            if (touch) lru_q[lookup_set] <= !update_way;
        end
    end
endmodule
