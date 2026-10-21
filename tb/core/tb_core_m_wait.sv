// Module: tb_core_m_wait
// Description: Checks queued MDU completion behind delayed memory, retained operands, and exact retirement.
module tb_core_m_wait;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import rv_asm_pkg::*;

    localparam int LOAD_DELAY = (MUL_IMPL == MUL_SHIFT) ? XLEN + 9 : 9;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic imem_req_valid;
    xlen_t imem_req_addr;
    logic imem_req_ready;
    logic imem_rsp_valid;
    logic [31:0] imem_rsp_data;
    logic imem_rsp_ready;
    logic dmem_req_valid;
    logic dmem_req_write;
    xlen_t dmem_req_addr;
    xlen_t dmem_req_wdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic dmem_req_ready;
    logic dmem_rsp_valid;
    xlen_t dmem_rsp_rdata;
    logic dmem_rsp_ready;
    logic commit_valid;
    xlen_t commit_pc;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    logic commit_rd_we;
    xlen_t commit_rd_data;
    logic commit_exception;
    logic load_pending_q;
    xlen_t load_data_q;
    int load_delay_q;
    int store_delay_q;
    int loads;
    int stores;
    logic queued_result_seen;
    logic retired_source_seen;
    logic source_retired, first_load_retired, first_m_issued, store_wait_seen;
    retire_id_t first_m_id;
    logic completion_held;
    retire_completion_t held_completion;
    xlen_t stored_value;
    xlen_t expected [12];
    int retired = 0;
    int scenario, program_length, observation_cycle;
    int bind_cycle, capture_cycle, source_retire_cycle, target_issue_cycle, retained_cycles;
    retire_id_t source_id, load_id, target_id;
    logic source_bound, source_captured;

    always #5 clk = ~clk;
    logic imem_rsp_error = 1'b0;
    logic dmem_rsp_error = 1'b0;
    mem_size_e dmem_req_size;

    core dut (.commit_trace(), .imem_rsp_error_1(1'b0), .fence_i_commit(), .irq_software(1'b0), .irq_timer(1'b0), .irq_external(1'b0), .*);
    sim_imem #(.DEPTH_WORDS(32)) u_imem (
        .clk, .rst,
        .req_valid(imem_req_valid), .req_addr(imem_req_addr), .req_ready(imem_req_ready),
        .rsp_valid(imem_rsp_valid), .rsp_data(imem_rsp_data), .rsp_ready(imem_rsp_ready),
        .rsp_error(), .rsp_error_1()
    );

    // Load 通常等待九拍；移位乘法更慢，延长到 XLEN+9 以覆盖结果早于 Load 返回。
    // 每次 Store 首次可见后等待六拍才接收，禁止重复请求。
    assign dmem_req_ready = !load_pending_q && (!dmem_rsp_valid || dmem_rsp_ready) &&
                           (!dmem_req_write || store_delay_q >= 6);

    always_ff @(posedge clk) begin
        if (rst) begin
            load_pending_q <= 1'b0;
            load_delay_q <= 0;
            store_delay_q <= 0;
            dmem_rsp_valid <= 1'b0;
            dmem_rsp_rdata <= '0;
            load_data_q <= '0;
            loads <= 0;
            stores <= 0;
            stored_value <= '0;
        end else begin
            if (dmem_rsp_valid && dmem_rsp_ready)
                dmem_rsp_valid <= 1'b0;
            if (load_pending_q) begin
                if (load_delay_q == 0) begin
                    load_pending_q <= 1'b0;
                    dmem_rsp_valid <= 1'b1;
                    dmem_rsp_rdata <= load_data_q;
                end else
                    load_delay_q <= load_delay_q - 1;
            end
            if (dmem_req_valid && dmem_req_write && !dmem_req_ready)
                store_delay_q <= store_delay_q + 1;
            if (dmem_req_valid && dmem_req_ready) begin
                if (dmem_req_write) begin
                    dmem_rsp_valid <= 1'b1;
                    dmem_rsp_rdata <= '0;
                    stores <= stores + 1;
                    store_delay_q <= 0;
                    assert (dmem_req_wstrb[3:0] == 4'b1111)
                        else $fatal(1, "M wait Store lanes");
                    if (dmem_req_addr == xlen_t'(8)) begin
                        assert (stores == 0 && dmem_req_wdata[31:0] == 32'd50)
                            else $fatal(1, "M wait first Store repeated or wrong data");
                        // LW 地址 8 在 RV64 字对齐返回通道的低四字节。
                        stored_value <= xlen_t'(50);
                    end else
                        assert (dmem_req_addr == xlen_t'(16) && stores == 1 &&
                                dmem_req_wdata[31:0] == 32'd7)
                            else $fatal(1, "M wait final Store repeated or wrong data");
                end else begin
                    loads <= loads + 1;
                    load_pending_q <= 1'b1;
                    load_delay_q <= LOAD_DELAY;
                    assert ((dmem_req_addr == '0 && loads == 0) ||
                            (dmem_req_addr == xlen_t'(8) && loads == 1))
                        else $fatal(1, "M wait Load repeated or wrong address");
                    load_data_q <= scenario == 1 ? xlen_t'(7) :
                                   (dmem_req_addr == '0) ? xlen_t'(41) : stored_value;
                end
            end
        end
    end

    // 慢 Load 等待不阻止已发射的独立 M 完成；队列保存结果，退休仍等老 Load。
    // 已退休源值仍须留在 EX 的操作数槽中，不能因生产者槽释放而丢失。
    always @(posedge clk) begin
        if (rst) begin
            queued_result_seen = 1'b0;
            retired_source_seen = 1'b0;
            source_retired = 1'b0;
            first_load_retired = 1'b0;
            first_m_issued = 1'b0;
            first_m_id = '0;
            store_wait_seen = 1'b0;
            completion_held = 1'b0;
            held_completion = '0;
            observation_cycle = 0;
            bind_cycle = -1; capture_cycle = -1; source_retire_cycle = -1; target_issue_cycle = -1;
            retained_cycles = 0; source_bound = 0; source_captured = 0;
            source_id = '0; load_id = '0; target_id = '0;
        end else begin
            observation_cycle++;
            if (completion_held)
                assert (dut.mdu_complete_valid && dut.mdu_completion == held_completion)
                    else $fatal(1, "backpressured MDU completion changed ID or data");
            completion_held = dut.mdu_complete_valid && !dut.mdu_complete_ready;
            if (completion_held) held_completion = dut.mdu_completion;
            if (dmem_req_valid && dmem_req_write && !dmem_req_ready)
                store_wait_seen = 1'b1;
            if (scenario == 0) begin
                // 退休广播与发射可同沿发生，监测顺序不能额外要求隔一个周期。
                if (commit_valid && commit_pc == xlen_t'(16)) source_retired = 1'b1;
                if (dut.mdu_req_valid && dut.mdu_req_ready) begin
                    if (dut.d2_ex_q.pc == xlen_t'(8)) begin
                        assert (!first_m_issued && dut.mdu_request.operand_a == xlen_t'(7) &&
                                dut.mdu_request.operand_b == xlen_t'(7))
                            else $fatal(1, "independent MDU repeated or captured wrong operands");
                        first_m_issued = 1'b1;
                        first_m_id = dut.d2_ex_q.retire_id;
                    end
                    if (dut.d2_ex_q.pc == xlen_t'(24)) begin
                        $display("M_WAIT_SOURCE RV%0d retired=%0d operand_a=%0d operand_b=%0d id=%h",
                                 XLEN,source_retired,dut.mdu_request.operand_a,dut.mdu_request.operand_b,dut.d2_ex_q.retire_id);
                        // 独立 LSU 不再冻结 EX；正确前递允许在该源退休之前发射。
                        // 跨真实退休沿的保存性质由下一个分源等待场景单独强制覆盖。
                        assert (dut.mdu_request.operand_a == xlen_t'(9) &&
                                dut.mdu_request.operand_b == xlen_t'(7))
                            else $fatal(1, "DIV captured incorrect source values");
                        retired_source_seen = 1'b1;
                    end
                end
                if (dut.mdu_complete_valid && dut.mdu_complete_ready &&
                    first_m_issued && dut.mdu_completion.id == first_m_id) begin
                    assert (!queued_result_seen && load_pending_q && !first_load_retired &&
                            dut.mdu_completion.result.gpr_data == xlen_t'(49))
                        else $fatal(1, "independent MDU did not complete during the older Load wait");
                    queued_result_seen = 1'b1;
                end
                if (commit_valid && commit_pc == xlen_t'(4)) first_load_retired = 1'b1;
                if (commit_valid && commit_pc == xlen_t'(8))
                    assert (first_load_retired && queued_result_seen && dut.head_id == first_m_id)
                        else $fatal(1, "queued MDU retired before its older Load or lost ID");
            end else begin
                // 长旧 DIV 保持退休队头，使 ALU、Load、双源消费者都成为真实在途项。
                // 参考 ID 来自分配事件；先观察 EX 捕获 ALU 源，再观察它真实退休，最后才允许 DIV 发射。
                if (dut.dispatch_valid && dut.dispatch_ready) begin
                    if (dut.alloc_meta.pc == 12) source_id = dut.alloc_id;
                    if (dut.alloc_meta.pc == 16) load_id = dut.alloc_id;
                    if (dut.alloc_meta.pc == 20) begin
                        target_id = dut.alloc_id;
                        assert (dut.d2_packet.rs1_dependency.pending && dut.d2_packet.rs1_dependency.id == source_id &&
                                dut.d2_packet.rs2_dependency.pending && dut.d2_packet.rs2_dependency.id == load_id)
                            else $fatal(1, "split source consumer did not bind both complete producer IDs");
                        source_bound = 1; bind_cycle = observation_cycle;
                    end
                end
                if (dut.d2_ex_q.valid && dut.d2_ex_q.retire_id == target_id && source_bound) begin
                    if (dut.d2_ex_q.rs1_dependency.pending && dut.u_ex_operand_register.rs1_ready) begin
                        assert (!source_retired && !source_captured &&
                                dut.d2_ex_q.rs1_dependency.id == source_id && dut.ex_rs1_value == 9 &&
                                dut.d2_ex_q.rs2_dependency.pending && !dut.u_ex_operand_register.rs2_ready &&
                                dut.pipeline_actions.d2_ex == PIPE_HOLD)
                            else $fatal(1, "split source did not capture ALU value while independently awaiting Load");
                        source_captured = 1; capture_cycle = observation_cycle;
                    end
                    if (source_captured && observation_cycle > capture_cycle) begin
                        assert (!dut.d2_ex_q.rs1_dependency.pending && dut.d2_ex_q.rs1_data == 9)
                            else $fatal(1, "captured ALU source lost from EX packet");
                        if (source_retired) retained_cycles++;
                    end
                end
                if (commit_valid && commit_pc == 12) begin
                    assert (dut.head_id == source_id && source_captured && observation_cycle > capture_cycle &&
                            dut.d2_ex_q.valid && dut.d2_ex_q.retire_id == target_id &&
                            !dut.d2_ex_q.rs1_dependency.pending && dut.d2_ex_q.rs1_data == 9)
                        else $fatal(1, "producer did not retire after consumer captured and retained its value");
                    source_retired = 1; source_retire_cycle = observation_cycle;
                end
                if (dut.mdu_req_valid && dut.mdu_req_ready && dut.d2_ex_q.pc == 20) begin
                    assert (source_retired && observation_cycle > source_retire_cycle &&
                            dut.d2_ex_q.retire_id == target_id && target_issue_cycle < 0 &&
                            dut.mdu_request.operand_a == 9 && dut.mdu_request.operand_b == 7 && retained_cycles > 0)
                        else $fatal(1, "DIV did not use captured source after producer retirement");
                    target_issue_cycle = observation_cycle; retired_source_seen = 1;
                end
            end
        end
    end

    initial begin
        for (scenario = 0; scenario < 2; scenario++) begin
            @(negedge clk);
            rst = 1;
            retired = 0;
            for (int idx = 0; idx < 32; idx++) u_imem.mem[idx] = nop();
            if (scenario == 0) begin
                program_length = 12;
                u_imem.mem[0] = enc_addi(1, 0, 7); expected[0] = xlen_t'(7);
                u_imem.mem[1] = enc_lw(2, 0, 0); expected[1] = xlen_t'(41);
                u_imem.mem[2] = enc_mul(3, 1, 1); expected[2] = xlen_t'(49);
                u_imem.mem[3] = enc_addi(4, 3, 1); expected[3] = xlen_t'(50);
                u_imem.mem[4] = enc_addi(5, 0, 9); expected[4] = xlen_t'(9);
                u_imem.mem[5] = enc_sw(4, 0, 8); expected[5] = '0;
                u_imem.mem[6] = enc_div(6, 5, 1); expected[6] = xlen_t'(1);
                u_imem.mem[7] = enc_mul(7, 6, 2); expected[7] = xlen_t'(41);
                u_imem.mem[8] = enc_lw(8, 0, 8); expected[8] = xlen_t'(50);
                u_imem.mem[9] = enc_div(9, 8, 1); expected[9] = xlen_t'(7);
                u_imem.mem[10] = enc_sw(9, 0, 16); expected[10] = '0;
                u_imem.mem[11] = enc_addi(10, 0, 1); expected[11] = xlen_t'(1);
                u_imem.mem[12] = enc_jal(0, 0);
            end else begin
                program_length = 7;
                u_imem.mem[0] = enc_addi(1, 0, 84); expected[0] = 84;
                u_imem.mem[1] = enc_addi(2, 0, 7); expected[1] = 7;
                u_imem.mem[2] = enc_div(3, 1, 2); expected[2] = 12;
                u_imem.mem[3] = enc_addi(5, 0, 9); expected[3] = 9;
                u_imem.mem[4] = enc_lw(8, 0, 0); expected[4] = 7;
                u_imem.mem[5] = enc_div(6, 5, 8); expected[5] = 1;
                u_imem.mem[6] = enc_addi(10, 0, 1); expected[6] = 1;
                u_imem.mem[7] = enc_jal(0, 0);
            end
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            for (int cycles = 0; cycles < 1000; cycles++) begin
                @(negedge clk);
                if (commit_valid) begin
                    assert (!commit_exception && commit_pc == xlen_t'(retired*4) &&
                            commit_inst == u_imem.mem[retired])
                        else $fatal(1, "M wait duplicate/out-of-order retirement pc=%h expected=%0d", commit_pc, retired*4);
                    if (scenario == 0 && (retired == 5 || retired == 10))
                        assert (!commit_rd_we) else $fatal(1, "Store wrote GPR");
                    else
                        assert (commit_rd_we && commit_rd_data == expected[retired])
                            else $fatal(1, "M wait pc=%h got=%h expected=%h", commit_pc, commit_rd_data, expected[retired]);
                    retired++;
                    if (retired == program_length) begin
                        if (scenario == 0) begin
                            assert (loads == 2 && stores == 2 && queued_result_seen &&
                                    retired_source_seen && store_wait_seen)
                                else $fatal(1, "M wait coverage loads=%0d stores=%0d queued=%b retained=%b store_wait=%b",
                                            loads, stores, queued_result_seen, retired_source_seen, store_wait_seen);
                        end else begin
                            assert (loads == 1 && stores == 0 && retired_source_seen &&
                                    bind_cycle < capture_cycle && capture_cycle < source_retire_cycle &&
                                    source_retire_cycle < target_issue_cycle && retained_cycles > 0)
                                else $fatal(1, "split source lifetime coverage missing");
                            $display("M_WAIT_CAPTURE RV%0d MUL=%0d DIV=%0d producer=%h consumer=%h bind=%0d capture=%0d retire=%0d issue=%0d retained=%0d",
                                XLEN,MUL_IMPL,DIV_IMPL,source_id,target_id,bind_cycle,capture_cycle,source_retire_cycle,target_issue_cycle,retained_cycles);
                        end
                        $display("M_WAIT_SCENARIO RV%0d scenario=%0d cycles=%0d", XLEN, scenario, cycles);
                        break;
                    end
                end
            end
            assert (retired == program_length) else $fatal(1, "M wait program timeout");
            @(negedge clk);
        end
        $display("PASS tb_core_m_wait RV%0d MUL=%0d DIV=%0d scenarios=2", XLEN,MUL_IMPL,DIV_IMPL);
        $finish;
    end
endmodule
