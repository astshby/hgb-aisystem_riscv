// Module: tb_block_arbiter
// Description: Independent block ownership, locked-offer, fairness and shared-memory channel checks.
module tb_block_arbiter;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    localparam int CLIENTS = 4;
    logic clk = 1'b0, rst = 1'b1;
    logic [CLIENTS-1:0] c_rd_cmd_valid, c_rd_cmd_ready, c_rd_valid, c_rd_ready;
    logic [CLIENTS-1:0] c_wr_cmd_valid, c_wr_cmd_ready, c_wr_valid, c_wr_ready;
    logic [CLIENTS-1:0] c_wr_rsp_valid, c_wr_rsp_ready;
    block_cmd_t c_rd_cmd [CLIENTS], c_wr_cmd [CLIENTS];
    block_r_t c_rd_data [CLIENTS];
    block_w_t c_wr_data [CLIENTS];
    block_b_t c_wr_rsp [CLIENTS];
    logic rd_cmd_valid, rd_cmd_ready, rd_valid, rd_ready;
    logic wr_cmd_valid, wr_cmd_ready, wr_valid, wr_ready, wr_rsp_valid, wr_rsp_ready;
    block_cmd_t rd_cmd, wr_cmd;
    block_r_t rd_data;
    block_w_t wr_data;
    block_b_t wr_rsp;
    logic [7:0] memory [8192];
    int r_phase [CLIENTS], w_phase [CLIENTS], r_sequence [CLIENTS], w_sequence [CLIENTS];
    int w_client_beat [CLIENTS], r_wait_grants [CLIENTS], w_wait_grants [CLIENTS];
    block_cmd_t r_offer [CLIENTS], w_offer [CLIENTS], read_owner_cmd, write_owner_cmd;
    block_w_t w_payload [CLIENTS];
    logic w_offer_valid [CLIENTS];
    int read_owner, write_owner, read_locked, write_locked, read_next, write_next;
    int read_beat, write_beat, write_delay, target_transactions;
    logic read_payload_valid, write_response_valid;
    block_r_t read_payload;
    block_b_t write_response;
    logic [31:0] random_state;
    logic [CLIENTS-1:0] read_mask, write_mask;
    logic random_stalls, command_block, response_block, data_block;
    int checks = 0, cycles = 0, read_accepts = 0, write_accepts = 0;
    int read_completes = 0, write_completes = 0, read_beats = 0, write_beats = 0;
    int overlap_cycles = 0, distinct_owners = 0, locked_checks = 0, b_owner_checks = 0;
    int error_checks = 0, fairness_max = 0, resets = 0, reset_read_aborts = 0, reset_write_aborts = 0;

    always #5 clk = ~clk;
    block_arbiter #(.CLIENTS(CLIENTS)) dut (.*);

    function automatic logic [31:0] random_word;
        random_state ^= random_state << 13;
        random_state ^= random_state >> 17;
        random_state ^= random_state << 5;
        return random_state;
    endfunction

    function automatic block_cmd_t make_command(input int client, sequence_number);
        block_cmd_t result;
        result = '0;
        result.addr = xlen_t'(32'(client*1024 + (sequence_number%8)*128));
        if (XLEN == 64) result.addr |= xlen_t'(64'h0000_0001_0000_0000);
        result.len = 8'(sequence_number%4);
        result.size = 3'd5;
        result.execute = 1'(client%2);
        return result;
    endfunction

    function automatic block_w_t make_write(input int client, sequence_number, beat);
        block_w_t result;
        result = '0;
        for (int lane = 0; lane < 32; lane++)
            result.data[lane*8 +: 8] = 8'(client*47 + sequence_number*13 + beat*7 + lane);
        result.strb = sequence_number%2 == 0 ? 32'hffff_ffff : 32'h5aa5_c33c;
        result.last = beat == sequence_number%4;
        return result;
    endfunction

    function automatic int choose_client(input logic [CLIENTS-1:0] offers, input int next_client, locked);
        int result;
        result = locked;
        if (result < 0)
            for (int i = 0; i < CLIENTS; i++)
                if (result < 0 && offers[(next_client+i)%CLIENTS]) result = (next_client+i)%CLIENTS;
        return result;
    endfunction

    // 客户端只在前笔完整结束后发下一命令；valid被反压时不随机撤销。
    // 所有读写共享一份字节存储，R展示时快照，W握手时按byte strobe生效。
    task automatic step;
        int expected_read, expected_write, r_client_fire, w_client_fire;
        logic take_read, take_write, take_r, take_w, take_b;
        logic [CLIENTS-1:0] expected_mask;
        checks++;
        cycles++;
        for (int client = 0; client < CLIENTS; client++) begin
            if (r_phase[client] == 0 && read_mask[client] && r_sequence[client] < target_transactions) begin
                r_offer[client] = make_command(client, r_sequence[client]);
                r_phase[client] = 1;
            end
            if (w_phase[client] == 0 && write_mask[client] && w_sequence[client] < target_transactions) begin
                w_offer[client] = make_command(client, w_sequence[client]);
                w_offer[client].execute = 1'b0;
                w_phase[client] = 1;
            end
            if (w_phase[client] == 2 && !w_offer_valid[client] &&
                w_client_beat[client] <= int'(w_offer[client].len) &&
                (!random_stalls || random_word()%4 != 0)) begin
                w_payload[client] = make_write(client, w_sequence[client], w_client_beat[client]);
                w_offer_valid[client] = 1'b1;
            end
            c_rd_cmd_valid[client] = r_phase[client] == 1;
            c_wr_cmd_valid[client] = w_phase[client] == 1;
            c_rd_cmd[client] = r_offer[client];
            c_wr_cmd[client] = w_offer[client];
            c_wr_valid[client] = w_offer_valid[client];
            c_wr_data[client] = w_payload[client];
            c_rd_ready[client] = !response_block && (!random_stalls || random_word()%4 != 0);
            c_wr_rsp_ready[client] = !response_block && (!random_stalls || random_word()%4 != 0);
        end
        if (read_owner >= 0 && !read_payload_valid && (!random_stalls || random_word()%4 != 0)) begin
            read_payload = '0;
            for (int lane = 0; lane < 32; lane++)
                read_payload.data[lane*8 +: 8] = memory[(int'(read_owner_cmd.addr)+read_beat*32+lane)&8191];
            read_payload.last = read_beat == int'(read_owner_cmd.len);
            read_payload.error = r_sequence[read_owner]%5 == 4 ? BUS_SLVERR : BUS_OK;
            read_payload_valid = 1'b1;
        end
        if (write_owner >= 0 && write_beat > int'(write_owner_cmd.len) && !write_response_valid) begin
            if (write_delay == 0) begin
                write_response.error = w_sequence[write_owner]%5 == 4 ? BUS_DECERR : BUS_OK;
                write_response_valid = 1'b1;
            end else write_delay--;
        end
        rd_cmd_ready = !command_block && (!random_stalls || random_word()%3 != 0);
        wr_cmd_ready = !command_block && (!random_stalls || random_word()%3 != 0);
        wr_ready = !data_block && (!random_stalls || random_word()%3 != 0);
        rd_valid = read_payload_valid;
        rd_data = read_payload;
        wr_rsp_valid = write_response_valid;
        wr_rsp = write_response;
        #1;
        expected_read = choose_client(c_rd_cmd_valid, read_next, read_locked);
        expected_write = choose_client(c_wr_cmd_valid, write_next, write_locked);
        assert (rd_cmd_valid == (read_owner < 0 && expected_read >= 0)) else $fatal(1, "Read command eligibility");
        assert (wr_cmd_valid == (write_owner < 0 && expected_write >= 0)) else $fatal(1, "Write command eligibility");
        expected_mask = '0;
        if (read_owner < 0 && expected_read >= 0) begin
            expected_mask[expected_read] = rd_cmd_ready;
            assert (rd_cmd == r_offer[expected_read]) else $fatal(1, "Read offer changed or wrong RR client");
        end
        assert (c_rd_cmd_ready == expected_mask) else $fatal(1, "Read command ready owner");
        expected_mask = '0;
        if (write_owner < 0 && expected_write >= 0) begin
            expected_mask[expected_write] = wr_cmd_ready;
            assert (wr_cmd == w_offer[expected_write]) else $fatal(1, "Write offer changed or wrong RR client");
        end
        assert (c_wr_cmd_ready == expected_mask) else $fatal(1, "Write command ready owner");
        expected_mask = '0;
        if (read_owner >= 0) expected_mask[read_owner] = rd_valid;
        assert (c_rd_valid == expected_mask && rd_ready == (read_owner >= 0 && c_rd_ready[read_owner]))
            else $fatal(1, "Read response owner");
        if (read_owner >= 0 && rd_valid)
            assert (c_rd_data[read_owner] == read_payload) else $fatal(1, "Read data/error/last corruption");
        expected_mask = '0;
        if (write_owner >= 0) expected_mask[write_owner] = wr_ready;
        assert (c_wr_ready == expected_mask && wr_valid == (write_owner >= 0 && c_wr_valid[write_owner]))
            else $fatal(1, "W ownership or interleaving");
        if (wr_valid) assert (wr_data == make_write(write_owner, w_sequence[write_owner], write_beat))
            else $fatal(1, "W data/strobe/last corruption");
        expected_mask = '0;
        if (write_owner >= 0) expected_mask[write_owner] = wr_rsp_valid;
        assert (c_wr_rsp_valid == expected_mask && wr_rsp_ready == (write_owner >= 0 && c_wr_rsp_ready[write_owner]))
            else $fatal(1, "B ownership");
        if (write_owner >= 0 && wr_rsp_valid)
            assert (c_wr_rsp[write_owner] == write_response) else $fatal(1, "B error corruption");
        if (read_locked >= 0 || write_locked >= 0) locked_checks++;
        if (read_owner >= 0 && write_owner >= 0) begin
            overlap_cycles++;
            if (read_owner != write_owner) distinct_owners++;
        end
        if (write_owner >= 0 && write_beat > int'(write_owner_cmd.len)) begin
            assert (!wr_cmd_valid) else $fatal(1, "Write owner released before B handshake");
            b_owner_checks++;
        end
        take_read = rd_cmd_valid && rd_cmd_ready;
        take_write = wr_cmd_valid && wr_cmd_ready;
        take_r = rd_valid && rd_ready;
        take_w = wr_valid && wr_ready;
        take_b = wr_rsp_valid && wr_rsp_ready;
        r_client_fire = expected_read;
        w_client_fire = expected_write;
        @(posedge clk);
        #1;
        if (rd_cmd_valid && !rd_cmd_ready && read_owner < 0) read_locked = expected_read;
        if (wr_cmd_valid && !wr_cmd_ready && write_owner < 0) write_locked = expected_write;
        if (take_read) begin
            read_owner = r_client_fire;
            read_owner_cmd = r_offer[r_client_fire];
            read_beat = 0;
            read_locked = -1;
            r_phase[r_client_fire] = 2;
            read_accepts++;
            for (int client = 0; client < CLIENTS; client++) begin
                if (client == r_client_fire) r_wait_grants[client] = 0;
                else if (r_phase[client] == 1) r_wait_grants[client]++;
                assert (r_wait_grants[client] < CLIENTS) else $fatal(1, "Read RR starvation under progress");
                if (r_wait_grants[client] > fairness_max) fairness_max = r_wait_grants[client];
            end
        end
        if (take_write) begin
            write_owner = w_client_fire;
            write_owner_cmd = w_offer[w_client_fire];
            write_beat = 0;
            write_delay = 5;
            write_locked = -1;
            w_phase[w_client_fire] = 2;
            w_client_beat[w_client_fire] = 0;
            write_accepts++;
            for (int client = 0; client < CLIENTS; client++) begin
                if (client == w_client_fire) w_wait_grants[client] = 0;
                else if (w_phase[client] == 1) w_wait_grants[client]++;
                assert (w_wait_grants[client] < CLIENTS) else $fatal(1, "Write RR starvation under progress");
                if (w_wait_grants[client] > fairness_max) fairness_max = w_wait_grants[client];
            end
        end
        if (take_r) begin
            read_payload_valid = 1'b0;
            read_beats++;
            if (read_payload.error != BUS_OK) error_checks++;
            if (read_payload.last) begin
                read_next = (read_owner+1)%CLIENTS;
                r_phase[read_owner] = 0;
                r_sequence[read_owner]++;
                read_owner = -1;
                read_completes++;
            end else read_beat++;
        end
        if (take_w) begin
            for (int lane = 0; lane < 32; lane++)
                if (w_payload[write_owner].strb[lane])
                    memory[(int'(write_owner_cmd.addr)+write_beat*32+lane)&8191] = w_payload[write_owner].data[lane*8 +: 8];
            w_offer_valid[write_owner] = 1'b0;
            w_client_beat[write_owner]++;
            write_beat++;
            write_beats++;
        end
        if (take_b) begin
            assert (write_beat == int'(write_owner_cmd.len)+1) else $fatal(1, "B before all W");
            if (write_response.error != BUS_OK) error_checks++;
            write_next = (write_owner+1)%CLIENTS;
            w_phase[write_owner] = 0;
            w_sequence[write_owner]++;
            write_owner = -1;
            write_response_valid = 1'b0;
            write_completes++;
        end
        @(negedge clk);
    endtask

    // 协调复位同时丢弃client和模拟外存的在途事务，不把单边复位当作可取消协议。
    task automatic reset_all;
        if (read_owner >= 0) reset_read_aborts++;
        if (write_owner >= 0) reset_write_aborts++;
        rst = 1'b1;
        c_rd_cmd_valid = '0; c_wr_cmd_valid = '0; c_wr_valid = '0;
        c_rd_ready = '0; c_wr_rsp_ready = '0;
        rd_cmd_ready = 0; wr_cmd_ready = 0; wr_ready = 0; rd_valid = 0; wr_rsp_valid = 0;
        #1;
        assert (!rd_cmd_valid && !wr_cmd_valid && !wr_valid && !rd_ready && !wr_rsp_ready &&
                c_rd_valid == 0 && c_wr_rsp_valid == 0 && c_rd_cmd_ready == 0 && c_wr_cmd_ready == 0)
            else $fatal(1, "Reset leaked ownership");
        repeat (2) @(negedge clk);
        read_owner = -1; write_owner = -1; read_locked = -1; write_locked = -1;
        read_next = 0; write_next = 0; read_beat = 0; write_beat = 0; write_delay = 0;
        read_payload_valid = 0; write_response_valid = 0;
        read_payload = '0; write_response = '0;
        for (int client = 0; client < CLIENTS; client++) begin
            r_phase[client] = 0; w_phase[client] = 0;
            r_sequence[client] = 0; w_sequence[client] = 0;
            w_client_beat[client] = 0; w_offer_valid[client] = 0;
            r_wait_grants[client] = 0; w_wait_grants[client] = 0;
            r_offer[client] = '0; w_offer[client] = '0; w_payload[client] = '0;
        end
        rst = 1'b0;
        resets++;
    endtask

    task automatic finish_round;
        logic finished;
        finished = 0;
        for (int timeout = 0; timeout < 10000 && !finished; timeout++) begin
            step();
            finished = read_owner < 0 && write_owner < 0;
            for (int client = 0; client < CLIENTS; client++) begin
                if (read_mask[client] && r_sequence[client] != target_transactions) finished = 0;
                if (write_mask[client] && w_sequence[client] != target_transactions) finished = 0;
            end
        end
        assert (finished) else $fatal(1, "Round timeout");
    endtask

    initial begin
        random_state = 32'hb10c_4031;
        if ($value$plusargs("SEED=%d", random_state)) begin end
        read_owner = -1; write_owner = -1;
        foreach (memory[i]) memory[i] = 8'(i*17+3);
        read_mask = '0; write_mask = '0;
        random_stalls = 0; command_block = 0; response_block = 0; data_block = 0;
        target_transactions = 1;
        @(negedge clk);
        reset_all();
        // 先展示低优先client，再到达轮询起点client；两个方向都必须保留锁定项。
        read_mask = 4'b1000; write_mask = 4'b0100; command_block = 1;
        step();
        read_mask = 4'b1001; write_mask = 4'b0101;
        repeat (3) step();
        assert (read_locked == 3 && write_locked == 2) else $fatal(1, "Late-arrival setup absent");
        command_block = 0;
        finish_round();
        // 持续竞争且从端最终前进：检查轮询服务次序和最多三个其他grant越过等待者。
        reset_all();
        read_mask = '1; write_mask = '1;
        target_transactions = 12;
        random_stalls = 1;
        finish_round();
        // 锁定offer、部分R/W、已完成W但B被反压三个阶段分别协调复位。
        for (int phase = 0; phase < 3; phase++) begin
            reset_all();
            random_stalls = 0; target_transactions = 2;
            command_block = phase == 0;
            response_block = phase == 2;
            data_block = phase == 1;
            if (phase == 0) repeat (3) step();
            else if (phase == 1) begin
                repeat (3) step();
                assert (write_owner >= 0) else $fatal(1, "No active W reset coverage");
            end else begin
                repeat (12) step();
                assert (read_owner >= 0 && write_response_valid) else $fatal(1, "No held R/B reset coverage");
            end
        end
        reset_all();
        command_block = 0; response_block = 0; data_block = 0;
        target_transactions = 4;
        finish_round();
        assert (read_accepts-read_completes == reset_read_aborts &&
                write_accepts-write_completes == reset_write_aborts)
            else $fatal(1, "Lost or duplicated transaction across coordinated reset");
        assert (overlap_cycles > 10 && distinct_owners > 0 && locked_checks > 3 &&
                b_owner_checks > 10 && error_checks > 0 && fairness_max == CLIENTS-1)
            else $fatal(1, "Missing concurrency/lock/fairness/error coverage");
        $display("PASS tb_block_arbiter XLEN=%0d checks=%0d cycles=%0d rd=%0d/%0d wr=%0d/%0d beats=%0d/%0d overlap=%0d distinct=%0d lock=%0d Bowner=%0d errors=%0d max_bypass=%0d resets=%0d abort=%0d/%0d",
            XLEN, checks, cycles, read_accepts, read_completes, write_accepts, write_completes,
            read_beats, write_beats, overlap_cycles, distinct_owners, locked_checks, b_owner_checks,
            error_checks, fairness_max, resets, reset_read_aborts, reset_write_aborts);
        $finish;
    end
endmodule
