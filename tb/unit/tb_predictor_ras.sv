// Module: tb_predictor_ras
// Description: Checks RAS hints, full-content recovery and priorities against independent software stacks.
module tb_predictor_ras #(
    parameter int unsigned DEPTH = 4,
    parameter int unsigned REPLAY_SLOTS = 8
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import predictor_types_pkg::*;
    import riscv_unpriv_pkg::*;
    logic clk = 0, rst = 1, clear = 0, fetch_fire = 0, commit_valid = 0, recover = 0;
    ras_event_t fetch_event, fetch_event_1, commit_event, commit_event_1, replay [REPLAY_SLOTS];
    logic fetch_second = 0;
    logic commit_valid_1 = 0;
    logic [REPLAY_SLOTS-1:0] replay_valid;
    logic top_valid;
    xlen_t top_addr;
    logic [31:0] inst;
    ras_op_e decoded_op;
    ras #(.DEPTH(DEPTH), .REPLAY_SLOTS(REPLAY_SLOTS)) dut (.*);
    ras_decode decode_dut (.inst, .op(decoded_op));
    always #5 clk = ~clk;

    // 模型使用最老项在前的动态队列，与 RTL 的固定移位栈方向、计数实现不同。
    xlen_t committed_model[$], speculative_model[$];
    int cycles = 0, checks = 0, decode_checks = 0;
    int recoveries = 0, simultaneous = 0, blocked_fetches = 0, dual_commits = 0;
    int dual_fetches = 0, boundary_recoveries = 0;
    logic [31:0] random_q = 32'h7b13e609;

    function automatic logic [31:0] random_word();
        random_q ^= random_q << 13;
        random_q ^= random_q >> 17;
        random_q ^= random_q << 5;
        return random_q;
    endfunction

    task automatic apply_model(ref xlen_t stack[$], input ras_event_t event_in);
        xlen_t discarded;
        if (event_in.op == RAS_POP || event_in.op == RAS_POP_PUSH)
            if (stack.size() != 0) discarded = stack.pop_back();
        if (event_in.op == RAS_PUSH || event_in.op == RAS_POP_PUSH) begin
            stack.push_back(event_in.addr);
            if (stack.size() > DEPTH) discarded = stack.pop_front();
        end
    endtask

    task automatic check_top();
        assert (top_valid == (speculative_model.size() != 0))
            else $fatal(1, "RAS validity cycle=%0d", cycles);
        if (speculative_model.size() != 0)
            assert (top_addr == speculative_model[speculative_model.size()-1])
                else $fatal(1, "RAS address cycle=%0d actual=%h expected=%h", cycles,
                            top_addr, speculative_model[speculative_model.size()-1]);
        checks++;
    endtask

    // 调用方始终在下降沿驱动；沿前检查禁止提交/恢复直接旁路到查询。
    task automatic tick();
        #1;
        if (cycles != 0) check_top();
        @(posedge clk);
        if (rst || clear) begin
            committed_model.delete();
            speculative_model.delete();
        end else begin
            if (commit_valid) apply_model(committed_model, commit_event);
            if (commit_valid_1) begin apply_model(committed_model, commit_event_1); dual_commits++; end
            if (recover) begin
                speculative_model = committed_model;
                for (int i = 0; i < REPLAY_SLOTS; i++)
                    if (replay_valid[i]) apply_model(speculative_model, replay[i]);
                recoveries++;
                if (commit_valid && fetch_fire) simultaneous++;
            end else if (fetch_fire) begin
                apply_model(speculative_model, fetch_event);
                if (fetch_second) begin
                    apply_model(speculative_model, fetch_event_1);
                    dual_fetches++;
                end
            end
            else if (fetch_event.op != RAS_NONE) blocked_fetches++;
        end
        cycles++;
        #1; check_top();
        @(negedge clk);
    endtask

    task automatic idle_inputs();
        clear = 0; fetch_fire = 0; commit_valid = 0; commit_valid_1 = 0; recover = 0;
        fetch_second = 0; fetch_event = '0; fetch_event_1 = '0;
        commit_event = '0; commit_event_1 = '0; replay_valid = '0;
        foreach (replay[i]) replay[i] = '0;
    endtask

    task automatic fetch_step(input ras_op_e op, input xlen_t addr, input bit accepted = 1);
        idle_inputs();
        fetch_fire = accepted;
        fetch_event = '{op:op, addr:addr};
        tick();
    endtask

    initial begin
        bit rd_link, rs1_link;
        ras_op_e expected;
        logic [31:0] sample;
        idle_inputs(); inst = '0;
        // 全部 rd/rs1 和 JALR funct3；错误编码不能产生返回栈 hint。
        for (int rd = 0; rd < 32; rd++) begin
            rd_link = rd == 1 || rd == 5;
            inst = {20'b0, 5'(rd), OPCODE_JAL}; #1;
            assert (decoded_op == (rd_link ? RAS_PUSH : RAS_NONE)) else $fatal(1, "JAL hint");
            decode_checks++;
            for (int rs1 = 0; rs1 < 32; rs1++) begin
                rs1_link = rs1 == 1 || rs1 == 5;
                if (rd_link && rs1_link) expected = rd == rs1 ? RAS_PUSH : RAS_POP_PUSH;
                else if (rd_link) expected = RAS_PUSH;
                else if (rs1_link) expected = RAS_POP;
                else expected = RAS_NONE;
                for (int f3 = 0; f3 < 8; f3++) begin
                    inst = {12'h81f, 5'(rs1), 3'(f3), 5'(rd), OPCODE_JALR}; #1;
                    assert (decoded_op == (f3 == 0 ? expected : RAS_NONE))
                        else $fatal(1, "JALR hint rd=%0d rs1=%0d f3=%0d", rd, rs1, f3);
                    decode_checks++;
                end
            end
        end
        for (int opcode = 0; opcode < 128; opcode++) begin
            if (7'(opcode) != OPCODE_JAL && 7'(opcode) != OPCODE_JALR) begin
                inst = {12'b0, 5'd5, 3'b0, 5'd1, 7'(opcode)}; #1;
                assert (decoded_op == RAS_NONE) else $fatal(1, "non-jump hint");
                decode_checks++;
            end
        end
        @(negedge clk); tick(); rst = 0;
        fetch_step(RAS_POP, '0);
        fetch_step(RAS_POP_PUSH, xlen_t'(16));
        fetch_step(RAS_PUSH, xlen_t'(20), 0);
        fetch_step(RAS_PUSH, xlen_t'(24), 0);
        fetch_step(RAS_POP_PUSH, xlen_t'(28));
        fetch_step(RAS_POP, '0);
        for (int i = 0; i < DEPTH + 3; i++) fetch_step(RAS_PUSH, xlen_t'(100 + i*4));
        for (int i = 0; i < DEPTH + 2; i++) fetch_step(RAS_POP, '0);

        // 完整填充 committed 后用错误路径溢出推测栈，恢复后逐项弹出验证所有内容。
        for (int i = 0; i < DEPTH; i++) begin
            idle_inputs(); commit_valid = 1;
            commit_event = '{op:RAS_PUSH, addr:xlen_t'(64'hf1234567_80000000 + 64'(i*4))};
            tick();
        end
        for (int i = 0; i < 2*DEPTH + 3; i++) fetch_step(RAS_PUSH, xlen_t'(300 + i*4));
        idle_inputs(); recover = 1; tick();
        for (int i = 0; i < DEPTH + 1; i++) fetch_step(RAS_POP, '0);

        // replay 只含尚未退休事件；同沿 commit 先应用，不能在 replay 中重复提交。
        idle_inputs(); recover = 1; commit_valid = 1; fetch_fire = 1;
        commit_event = '{op:RAS_PUSH, addr:xlen_t'(64'hfedcba98_76543210)};
        fetch_event = '{op:RAS_PUSH, addr:xlen_t'(999)};
        for (int i = 0; i < REPLAY_SLOTS; i++) begin
            replay_valid[i] = (i % 3 != 1);
            replay[i] = '{op:(i % 2 == 0 ? RAS_PUSH : RAS_POP_PUSH), addr:xlen_t'(500+i*4)};
        end
        tick();
        for (int i = 0; i < DEPTH + 1; i++) fetch_step(RAS_POP, '0);

        // clear 胜过提交、恢复和取指；下一次恢复也必须看到空 committed。
        idle_inputs(); clear = 1; recover = 1; commit_valid = 1; fetch_fire = 1;
        commit_event = '{op:RAS_PUSH, addr:xlen_t'(1000)};
        fetch_event = commit_event; replay_valid = '1;
        foreach (replay[i]) replay[i] = commit_event;
        tick(); idle_inputs(); recover = 1; tick();

        // 遍历所有 committed 深度；长重放覆盖满栈先推后弹造成的底部丢弃、空栈弹出和协程。
        for (int count = 0; count <= DEPTH; count++) begin
            for (int pattern = 0; pattern < 6; pattern++) begin
                idle_inputs(); clear = 1; tick();
                for (int i = 0; i < count; i++) begin
                    idle_inputs(); commit_valid = 1;
                    commit_event = '{op:RAS_PUSH, addr:xlen_t'(64'h2000+64'(i*4))};
                    tick();
                end
                idle_inputs(); recover = 1;
                for (int i = 0; i < REPLAY_SLOTS; i++) begin
                    replay_valid[i] = pattern != 5 || i % 3 != 1;
                    replay[i].addr = xlen_t'(64'hfedcba98_12340000 + 64'(i*4));
                    unique case (pattern)
                        0: replay[i].op = RAS_PUSH;
                        1: replay[i].op = RAS_POP;
                        2: replay[i].op = i % 2 == 0 ? RAS_PUSH : RAS_POP;
                        3: replay[i].op = i % 2 == 0 ? RAS_POP : RAS_PUSH;
                        4: replay[i].op = RAS_POP_PUSH;
                        default: replay[i].op = ras_op_e'(2'(i));
                    endcase
                end
                tick(); boundary_recoveries++;
                for (int i = 0; i <= DEPTH; i++) fetch_step(RAS_POP, '0);
            end
        end

        // 两个取指事件必须先老后年轻；恢复仍优先于同拍双取指，并包含同拍双退休。
        idle_inputs(); fetch_fire = 1; fetch_second = 1;
        fetch_event = '{op:RAS_PUSH, addr:xlen_t'(16'h3100)};
        fetch_event_1 = '{op:RAS_POP_PUSH, addr:xlen_t'(16'h3200)};
        tick();
        idle_inputs(); recover = 1; commit_valid = 1; commit_valid_1 = 1;
        fetch_fire = 1; fetch_second = 1;
        commit_event = '{op:RAS_PUSH, addr:xlen_t'(16'h4100)};
        commit_event_1 = '{op:RAS_POP_PUSH, addr:xlen_t'(16'h4200)};
        fetch_event = '{op:RAS_PUSH, addr:xlen_t'(16'h5100)};
        fetch_event_1 = '{op:RAS_PUSH, addr:xlen_t'(16'h5200)};
        tick();

        // 确定性组合事件压力；模型不依赖 DUT 内部数组或计数器。
        for (int i = 0; i < 1500; i++) begin
            idle_inputs(); sample = random_word();
            clear = sample[7:0] == 0;
            rst = i == 731;
            fetch_fire = sample[8]; commit_valid = sample[9]; recover = sample[11:10] == 0;
            commit_valid_1 = commit_valid && sample[16];
            fetch_second = sample[20];
            fetch_event_1 = '{op:ras_op_e'(sample[22:21]), addr:xlen_t'({sample, sample ^ 32'hc1234567})};
            fetch_event = '{op:ras_op_e'(sample[13:12]), addr:xlen_t'({sample, ~sample})};
            commit_event = '{op:ras_op_e'(sample[15:14]), addr:xlen_t'({~sample, sample})};
            commit_event_1 = '{op:ras_op_e'(sample[18:17]), addr:xlen_t'({sample ^ 32'h9876abcd, sample})};
            foreach (replay[j]) begin
                sample = random_word(); replay_valid[j] = sample[0];
                replay[j] = '{op:ras_op_e'(sample[2:1]), addr:xlen_t'({sample, sample ^ 32'h5a968721})};
            end
            tick();
        end
        rst = 0; idle_inputs(); recover = 1; tick();
        for (int i = 0; i < DEPTH + 1; i++) fetch_step(RAS_POP, '0);
        assert (recoveries > 100 && simultaneous > 20 && blocked_fetches > 100 && dual_commits > 100 &&
                dual_fetches > 100 && boundary_recoveries == 6*(DEPTH+1))
            else $fatal(1, "insufficient RAS event coverage");
        $display("PASS tb_predictor_ras RV%0d depth=%0d replay=%0d decode=%0d checks=%0d cycles=%0d recover=%0d simultaneous=%0d blocked=%0d dual_commit=%0d dual_fetch=%0d boundary_recover=%0d",
                 XLEN, DEPTH, REPLAY_SLOTS, decode_checks, checks, cycles, recoveries, simultaneous, blocked_fetches, dual_commits,
                 dual_fetches, boundary_recoveries);
        $finish;
    end
    initial begin #1000000; $fatal(1, "RAS watchdog"); end
endmodule
