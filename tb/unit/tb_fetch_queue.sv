// Module: tb_fetch_queue
// Description: Checks two-push/two-pop fetch buffering against an independent software FIFO.
module tb_fetch_queue #(
    parameter int DEPTH = 8
);
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;
    import predictor_types_pkg::*;
    import riscv_priv_pkg::*;

    logic clk = 0, rst = 1, flush = 0;
    if_d1_t push_packet, push_packet_1, out_packet, out_packet_1;
    logic [1:0] push_count = 0, pop_count = 0;
    logic push_ready;
    logic [$clog2(DEPTH+1)-1:0] occupancy;
    if_d1_t model[$];
    if_d1_t offered_0, offered_1;
    bit accepted_last;
    int serial = 0, checks = 0, pushes = 0, pops = 0, maximum = 0;
    int full_replace = 0, blocked_offer = 0, partial_pop = 0, no_bypass = 0;
    int flushes = 0, resets = 0, single_reserved = 0;
    int unsigned random_state = 32'h65c5_a817, initial_seed;

    always #5 clk = ~clk;
    fetch_queue #(.DEPTH(DEPTH)) dut (.*);

    function automatic int unsigned random_word();
        random_state ^= random_state << 13;
        random_state ^= random_state >> 17;
        random_state ^= random_state << 5;
        return random_state;
    endfunction

    function automatic if_d1_t packet(input int tag);
        if_d1_t value;
        value = '0;
        // valid 不授权入队，数量才授权；故意交替毒化输入 valid，输出须由队列拥有。
        value.valid = 1'(tag);
        value.pc = xlen_t'(64'h1234_5678_8000_0000) + xlen_t'(tag*4);
        value.seq_pc = value.pc + xlen_t'(4);
        value.inst = 32'h0000_0013 ^ (32'(tag) << 7);
        value.pred.hit = 1'(tag >> 1); value.pred.taken = 1'(tag >> 2);
        value.pred.target = xlen_t'(64'hfedc_ba98_1000_0000) ^ xlen_t'(tag*16);
        value.pred.btb_idx = BTB_IDX_W'(tag);
        value.pred.train.pht_idx = PHT_IDX_W'(tag >> 1);
        value.pred.train.local_idx = LOCAL_HISTORY_W'(tag*3);
        value.pred.train.chooser_idx = CHOOSER_IDX_W'(tag*5);
        value.pred.train.global_taken = 1'(tag >> 3);
        value.pred.train.local_taken = 1'(tag >> 4);
        value.pred.train.choose_local = 1'(tag >> 5);
        value.pred.ras_op = ras_op_e'(2'(tag));
        value.exc.valid = tag % 7 == 0;
        value.exc.cause = EXC_INST_ACCESS_FAULT;
        value.exc.tval = value.pc ^ xlen_t'(64'h7654_3210_0000_0000);
        return value;
    endfunction

    task automatic offer();
        offered_0 = packet(serial); serial++;
        offered_1 = packet(serial); serial++;
    endtask

    task automatic check_outputs(input string label_text);
        assert (int'(occupancy) == model.size())
            else $fatal(1, "%s: occupancy actual=%0d expected=%0d", label_text, occupancy, model.size());
        if (rst || flush) begin
            assert (!out_packet.valid && !out_packet_1.valid)
                else $fatal(1, "%s: reset/flush exposed output", label_text);
        end else begin
            assert (out_packet.valid == (model.size() >= 1) &&
                    out_packet_1.valid == (model.size() >= 2))
                else $fatal(1, "%s: output prefix validity", label_text);
            if (model.size() >= 1)
                assert (out_packet == model[0]) else $fatal(1, "%s: first payload/order mismatch", label_text);
            if (model.size() >= 2)
                assert (out_packet_1 == model[1]) else $fatal(1, "%s: second payload/order mismatch", label_text);
        end
    endtask

    // 在下降沿驱动，先检查沿前状态和无空队列旁路，再在上升沿更新独立软件队列。
    // pop_count 来自软件列表大小；不读 DUT occupancy/valid 决定参考内容。
    task automatic step(input string label_text, input int put_count, input int take_count,
                        input bit do_flush = 0, input bit do_reset = 0);
        bit expected_ready;
        int before_count;
        if_d1_t value, discarded;
        @(negedge clk);
        assert (take_count >= 0 && take_count <= 2 && take_count <= model.size() &&
                put_count >= 0 && put_count <= 2)
            else $fatal(1, "invalid test stimulus");
        rst = do_reset; flush = do_flush;
        push_packet = offered_0; push_packet_1 = offered_1;
        push_count = 2'(put_count); pop_count = 2'(take_count);
        before_count = model.size();
        expected_ready = !do_reset && !do_flush && DEPTH-before_count+take_count >= 2;
        #1;
        check_outputs(label_text);
        assert (push_ready == expected_ready) else $fatal(1, "%s: pair reservation ready mismatch", label_text);
        accepted_last = put_count != 0 && expected_ready;
        if (!do_reset && !do_flush) begin
            if (put_count != 0 && !expected_ready) blocked_offer++;
            if (put_count == 1 && DEPTH-before_count+take_count == 1) single_reserved++;
            if (before_count == 0 && put_count != 0) begin
                assert (!out_packet.valid && !out_packet_1.valid) else $fatal(1, "empty input bypassed storage");
                no_bypass++;
            end
            if (before_count == DEPTH && take_count == 2 && accepted_last && put_count == 2) full_replace++;
            if (take_count == 1 && before_count >= 2) partial_pop++;
        end
        @(posedge clk);
        if (do_reset || do_flush) begin
            model.delete();
            if (do_reset) resets++;
            if (do_flush) flushes++;
        end else begin
            repeat (take_count) begin discarded = model.pop_front(); pops++; end
            if (accepted_last) begin
                value = offered_0; value.valid = 1; model.push_back(value); pushes++;
                if (put_count == 2) begin
                    value = offered_1; value.valid = 1; model.push_back(value); pushes++;
                end
            end
        end
        if (model.size() > maximum) maximum = model.size();
        #1;
        check_outputs(label_text);
        checks++;
    endtask

    initial begin
        int pending_count, take_count;
        bit do_flush, do_reset;
        assert (DEPTH inside {2,4,8}) else $fatal(1, "TB supports DEPTH 2/4/8");
        if ($value$plusargs("SEED=%d", random_state)) begin end
        assert (random_state != 0) else $fatal(1, "SEED must be nonzero");
        initial_seed = random_state;
        offer(); step("initial reset", 2, 0, 0, 1);
        step("empty pair accepted without bypass", 2, 0);
        step("partial consume keeps second oldest", 0, 1);
        repeat (3) begin offer(); step("invalid push payload poison while head held", 0, 0); end
        while (model.size() != 0) step("drain prefix", 0, model.size() >= 2 ? 2 : 1);
        while (model.size() < DEPTH) begin offer(); step("fill", 2, 0); end
        repeat (8) begin offer(); step("full two-pop two-push wrap", 2, 2); end
        offer();
        repeat (3) step("blocked producer holds same pair", 2, 0);
        step("release blocked pair", 2, 2);
        step("make exactly one free slot", 0, 1);
        offer(); step("single push still reserves pair capacity", 1, 0);
        assert (!accepted_last) else $fatal(1, "one free slot incorrectly accepted single offer");
        step("single push with same-edge prefix release", 1, 1);
        assert (accepted_last) else $fatal(1, "same-edge pop did not authorize single offer");
        offer(); step("flush dominates push and pop", 2, model.size() >= 2 ? 2 : 1, 1);
        offer(); step("refill after flush", 2, 0);
        offer(); step("reset populated queue", 2, 2, 0, 1);

        pending_count = 0;
        for (int cycle = 0; cycle < 4000; cycle++) begin
            if (pending_count == 0) begin
                pending_count = int'(random_word() % 3);
                offer();
            end
            take_count = int'(random_word() % 3);
            if (take_count > model.size()) take_count = model.size();
            do_flush = random_word() % 97 == 0;
            do_reset = random_word() % 251 == 0;
            step("random FIFO", pending_count, take_count, do_flush, do_reset);
            // 发送者在反压期间保持同一 count/payload；只有接纳或协调清除才释放 offer。
            if (accepted_last || do_flush || do_reset) pending_count = 0;
        end
        if (pending_count != 0) begin
            while (!accepted_last) begin
                take_count = model.size() >= 2 ? 2 : model.size();
                step("finish held offer", pending_count, take_count);
            end
        end
        while (model.size() != 0) step("final drain", 0, model.size() >= 2 ? 2 : 1);
        assert (maximum == DEPTH && full_replace >= 8 && blocked_offer >= 3 && partial_pop > 0 &&
                no_bypass > 0 && single_reserved > 0 && flushes > 0 && resets >= 2)
            else $fatal(1, "FIFO coverage missing");
        $display("PASS tb_fetch_queue RV%0d depth=%0d seed=%0d checks=%0d pushes=%0d pops=%0d max=%0d full_replace=%0d blocked=%0d partial=%0d no_bypass=%0d reserve2=%0d flush=%0d reset=%0d",
            XLEN, DEPTH, initial_seed, checks, pushes, pops, maximum, full_replace, blocked_offer,
            partial_pop, no_bypass, single_reserved, flushes, resets);
        $finish;
    end
endmodule
