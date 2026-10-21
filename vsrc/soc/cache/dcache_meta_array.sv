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
    input logic update_way, touch_way,
    input logic [TAG_W-1:0] install_tag
);
    // valid/dirty 属于每个缓存行；LRU 属于整组，touch 与行写入分别选择 way。
    logic valid_q [SETS][2], dirty_q [SETS][2], lru_q [SETS];
    logic [TAG_W-1:0] tag_q [SETS][2];

    // 两路命中并行比较；同时命中时保留原有的 way 1 优先约定。
    always_comb begin
        hit_way = valid_q[lookup_set][1] && tag_q[lookup_set][1] == lookup_tag;
        hit = hit_way || (valid_q[lookup_set][0] && tag_q[lookup_set][0] == lookup_tag);
    end

    // 无效 way 优先，否则选择 LRU；输出只供控制器保存，不反馈到本拍 probe。
    always_comb begin
        victim_way = !valid_q[lookup_set][0] ? 0 : !valid_q[lookup_set][1] ? 1 : lru_q[lookup_set];
    end

    // 探测由已保存的 way 驱动，供替换与维护判断；无效行不报告 dirty。
    always_comb begin
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
            if (touch) lru_q[lookup_set] <= !touch_way;
        end
    end
endmodule
