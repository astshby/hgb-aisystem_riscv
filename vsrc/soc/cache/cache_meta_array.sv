// Module: cache_meta_array
// Description: Two-way tags, valid bits and exact one-bit LRU with invalidate priority.
module cache_meta_array #(
    parameter int unsigned SETS = 64,
    parameter int unsigned SET_W = $clog2(SETS),
    parameter int unsigned TAG_W = 21
) (
    input logic clk, rst, invalidate,
    input logic [SET_W-1:0] lookup_set,
    input logic [TAG_W-1:0] lookup_tag,
    output logic hit, hit_way, victim_way,
    input logic evict, install, touch,
    input logic update_way,
    input logic [SET_W-1:0] update_set,
    input logic [TAG_W-1:0] update_tag
);
    logic valid_q [SETS][2];
    logic [TAG_W-1:0] tag_q [SETS][2];
    logic lru_q [SETS];

    // 优先使用无效 way；两路全有效时，一位即可表示精确 LRU。
    always_comb begin
        hit_way = valid_q[lookup_set][1] && tag_q[lookup_set][1] == lookup_tag;
        hit = hit_way || (valid_q[lookup_set][0] && tag_q[lookup_set][0] == lookup_tag);
        victim_way = !valid_q[lookup_set][0] ? 1'b0 :
                     !valid_q[lookup_set][1] ? 1'b1 : lru_q[lookup_set];
    end

    // 全失效优先于末拍安装；未完整成功的填行一直保持 invalid。
    always_ff @(posedge clk) begin
        if (rst || invalidate) begin
            for (int s = 0; s < SETS; s++) begin
                valid_q[s][0] <= 1'b0;
                valid_q[s][1] <= 1'b0;
                lru_q[s] <= 1'b0;
            end
        end else begin
            if (evict) valid_q[update_set][update_way] <= 1'b0;
            if (install) begin
                valid_q[update_set][update_way] <= 1'b1;
                tag_q[update_set][update_way] <= update_tag;
            end
            if (touch) lru_q[update_set] <= !update_way;
        end
    end
endmodule
