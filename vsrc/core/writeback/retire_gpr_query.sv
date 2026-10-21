// Module: retire_gpr_query
// Description: Reads retirement-owned producers, registered values, and unretired MDU age without state.
module retire_gpr_query (
    input pipeline_pkg::retire_gpr_entry_t entries [core_config_pkg::RETIRE_ENTRIES],
    input logic [core_config_pkg::RETIRE_IDX_W-1:0] head_slot,
    input logic normal_retire,
    input pipeline_pkg::retire_id_t retiring_id,
    input logic normal_retire_1,
    input pipeline_pkg::retire_id_t retiring_id_1,
    input pipeline_pkg::retire_query_t query,
    output pipeline_pkg::retire_query_result_t query_result
);
    import core_config_pkg::*;
    import pipeline_pkg::*;

    logic [RETIRE_IDX_W-1:0] consumer_distance;
    logic [RETIRE_IDX_W-1:0] distance [RETIRE_ENTRIES];
    logic [RETIRE_ENTRIES-1:0] older, dispatch_writer;

    // 同代次的真实消费者才可查执行结果；环形距离表示年龄，ID 数值本身不表示年龄。
    always_comb begin
        consumer_distance = query.consumer_id.slot - head_slot;
        query_result = '0;
        query_result.consumer_live = query.consumer_valid &&
            entries[query.consumer_id.slot].valid &&
            (entries[query.consumer_id.slot].id == query.consumer_id);
        for (int slot = 0; slot < RETIRE_ENTRIES; slot++) begin
            distance[slot] = RETIRE_IDX_W'(slot) - head_slot;
            older[slot] = query_result.consumer_live && entries[slot].valid &&
                          (distance[slot] < consumer_distance);
            // D2 的寄存器读口有退休写穿透；同沿正常退休的写者不必再绑定。
            dispatch_writer[slot] = entries[slot].valid && entries[slot].gpr_write &&
                (entries[slot].rd != '0) &&
                !(normal_retire && entries[slot].id == retiring_id) &&
                !(normal_retire_1 && entries[slot].id == retiring_id_1);
        end

        // 接入者必须用 waw_block 阻止同名写者同时在途；因此每个源最多匹配一个生产者。
        // 异常或尚未完成的条目仍是生产者，不能退回旧寄存器值。
        for (int slot = 0; slot < RETIRE_ENTRIES; slot++) begin
            if (query.dispatch_valid && dispatch_writer[slot]) begin
                if (query.rs1_used && query.rs1 != '0 && entries[slot].rd == query.rs1) begin
                    query_result.rs1_dependency = '{pending:1'b1, id:entries[slot].id};
                    // D2 可直接选择已寄存、无异常的值；pending 仍描述真实生产者绑定。
                    if (entries[slot].ready)
                        query_result.dispatch_rs1 = '{valid:1'b1, id:entries[slot].id, data:entries[slot].data};
                end
                if (query.rs2_used && query.rs2 != '0 && entries[slot].rd == query.rs2) begin
                    query_result.rs2_dependency = '{pending:1'b1, id:entries[slot].id};
                    if (entries[slot].ready)
                        query_result.dispatch_rs2 = '{valid:1'b1, id:entries[slot].id, data:entries[slot].data};
                end
                if (query.gpr_write && query.rd != '0 && entries[slot].rd == query.rd)
                    query_result.waw_block = 1'b1;
            end
        end

        // EX 不排除本拍退休项：消费者必须能在生产者消失前逐源保存它的值。
        // 这里只读 done 后的寄存值；本拍新完成值走带 ID 的 WB/MDU 前递，不串回队列查询。
        for (int slot = 0; slot < RETIRE_ENTRIES; slot++) begin
            if (older[slot] && entries[slot].ready && entries[slot].gpr_write && entries[slot].rd != '0) begin
                if (query.rs1_dependency.pending && entries[slot].id == query.rs1_dependency.id)
                    query_result.rs1_forward = '{valid:1'b1, id:entries[slot].id, data:entries[slot].data};
                if (query.rs2_dependency.pending && entries[slot].id == query.rs2_dependency.id)
                    query_result.rs2_forward = '{valid:1'b1, id:entries[slot].id, data:entries[slot].data};
            end
            if (entries[slot].valid && entries[slot].kind == RET_MDU) begin
                // 完成不等于退休；MDU 已交付 RESULT 后，这条年龄屏障仍然存在。
                query_result.any_unretired_mdu = 1'b1;
                if (older[slot]) query_result.older_mdu_pending = 1'b1;
            end
        end
    end
endmodule
