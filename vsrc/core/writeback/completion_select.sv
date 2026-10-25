// Module: completion_select
// Description: Selects the two oldest held completions for an always-ready ROB.
module completion_select #(
    parameter int unsigned SOURCES = 5
) (
    input logic rst,
    input logic [core_config_pkg::RETIRE_IDX_W-1:0] head_slot,
    input logic [SOURCES-1:0] source_valid,
    // 接受位与年龄仲裁并行计算；选中后只做一次固定来源多路选择。
    input logic [SOURCES-1:0] source_accept,
    output logic [SOURCES-1:0] source_ready,
    input pipeline_pkg::retire_completion_t source_completion [SOURCES],
    output logic [1:0] complete_valid,
    output logic [1:0] complete_accept,
    output pipeline_pkg::retire_completion_t completion [2]
);
    import core_config_pkg::*;
    import pipeline_pkg::*;
    logic [SOURCES-1:0] preceding [SOURCES], select [2];
    logic [SOURCES-1:0] wrapped;
    // 年龄优先保证较老的长延迟结果不被连续 ALU 完成饿死；未获选的源继续持有结果。
    // 接收者必须每拍可接纳两条（包含拒绝旧 ID）；反压留在各执行源的结果槽。
    // 并行比较固定来源，避免逐项选择动态 age 索引形成串行比较/多路器链。
    for (genvar src = 0; src < SOURCES; src++) begin : g_rank
        assign wrapped[src] = source_completion[src].id.slot < head_slot;
        for (genvar other = 0; other < SOURCES; other++) begin : g_preceding
            assign preceding[src][other] = source_valid[other] &&
                ((wrapped[other] != wrapped[src]) ? wrapped[src] :
                 ((source_completion[other].id.slot < source_completion[src].id.slot) ||
                  ((source_completion[other].id.slot == source_completion[src].id.slot) && other < src)));
        end
        assign select[0][src] = !rst && source_valid[src] && !(|preceding[src]);
        // 恰好一个来源更老时占第二口；相同年龄按来源号稳定排序。
        assign select[1][src] = !rst && source_valid[src] && (|preceding[src]) &&
            ((preceding[src] & (preceding[src] - SOURCES'(1))) == '0);
    end
    assign source_ready = select[0] | select[1];
    always_comb begin
        for (int portno = 0; portno < 2; portno++) begin
            complete_valid[portno] = |select[portno];
            complete_accept[portno] = |(select[portno] & source_accept);
            completion[portno] = '0;
            for (int src = 0; src < SOURCES; src++)
                completion[portno] |= source_completion[src] &
                    {$bits(retire_completion_t){select[portno][src]}};
        end
    end
endmodule
