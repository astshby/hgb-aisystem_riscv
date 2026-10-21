// Module: tb_store_result_monitor
// Description: Checks tagged Store retirement, byte assembly, recovery, and precise negative protocol cases.
module tb_store_result_monitor #(
    parameter int unsigned RESULT_BYTES = 4
);
    timeunit 1ns;
    timeprecision 1ps;

    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    xlen_t result_addr;
    logic dmem_store_fire;
    xlen_t dmem_store_addr;
    xlen_t dmem_store_data;
    logic [DBUS_BYTES-1:0] dmem_store_strb;
    logic test_done;
    logic test_pass;
    logic [31:0] test_code;
    retire_id_t store_request_id, store_response_id, store_retire_id;
    logic store_response_fire, store_response_error, store_retire_fire, store_retire_error, cancel;
    byte unsigned reference_bytes [8];
    bit reference_valid [8];
    bit reference_done, reference_pass;
    logic [31:0] reference_code;
    int checks = 0, serial = 1, negative_case = 0;

    always #5 clk = ~clk;
    store_result_monitor #(.RESULT_BYTES(RESULT_BYTES)) dut (.*);

    task automatic tick;
        @(posedge clk);
        @(negedge clk);
    endtask

    task automatic check;
        assert (test_done == reference_done && test_pass == reference_pass && test_code == reference_code)
            else $fatal(1, "UNEXPECTED_MONITOR_RESULT check=%0d got=%b/%b/%h expected=%b/%b/%h",
                        checks, test_done, test_pass, test_code, reference_done, reference_pass, reference_code);
        checks++;
    endtask

    task automatic clear_reference;
        for (int i = 0; i < 8; i++) begin reference_bytes[i] = 0; reference_valid[i] = 0; end
        reference_done = 0; reference_pass = 0; reference_code = 0;
    endtask

    task automatic reset_monitor;
        @(negedge clk);
        rst = 1;
        dmem_store_fire = 0; store_response_fire = 0; store_retire_fire = 0; cancel = 0;
        store_response_error = 0; store_retire_error = 0;
        store_request_id = '0; store_response_id = '0; store_retire_id = '0;
        dmem_store_addr = 0; dmem_store_data = 0; dmem_store_strb = 0;
        clear_reference();
        tick(); tick(); rst = 0; check();
    endtask

    // 参考模型用绝对字节地址和除法/取余定位，不读取监视器的候选包或有效字节。
    task automatic reference_commit(input xlen_t address, input xlen_t data,
                                    input logic [DBUS_BYTES-1:0] strb);
        logic [63:0] value;
        bit all_valid;
        xlen_t absolute;
        int lane;
        if (!reference_done) begin
            for (int i = 0; i < RESULT_BYTES; i++) begin
                absolute = result_addr + xlen_t'(i);
                lane = int'(absolute % DBUS_BYTES);
                if (absolute / DBUS_BYTES == address / DBUS_BYTES && strb[lane]) begin
                    reference_bytes[i] = byte'(data >> (8*lane));
                    reference_valid[i] = 1;
                end
            end
            value = 0; all_valid = 1;
            for (int i = 0; i < RESULT_BYTES; i++) begin
                value |= 64'(reference_bytes[i]) << (8*i);
                all_valid &= reference_valid[i];
            end
            if (all_valid) begin
                if (value != 0) begin
                    reference_done = 1; reference_pass = value == 1; reference_code = value[31:0];
                end else begin
                    for (int i = 0; i < RESULT_BYTES; i++) reference_valid[i] = 0;
                end
            end
        end
    endtask

    task automatic request_store(input xlen_t address, input xlen_t data,
                                  input logic [DBUS_BYTES-1:0] strb, input retire_id_t id);
        dmem_store_fire = 1; dmem_store_addr = address; dmem_store_data = data;
        dmem_store_strb = strb; store_request_id = id;
        tick(); dmem_store_fire = 0; check();
        // 接受后修改裸总线载荷，证明退休使用的是请求时保存的数据。
        dmem_store_addr = '1; dmem_store_data = '1; dmem_store_strb = '0;
    endtask

    task automatic response(input retire_id_t id, input bit error = 0);
        store_response_fire = 1; store_response_id = id; store_response_error = error;
        tick(); store_response_fire = 0; check();
    endtask

    task automatic retire(input retire_id_t id, input xlen_t address, input xlen_t data,
                          input logic [DBUS_BYTES-1:0] strb, input bit error = 0);
        store_retire_fire = 1; store_retire_id = id; store_retire_error = error;
        if (error) clear_reference(); else reference_commit(address, data, strb);
        tick(); store_retire_fire = 0; store_retire_error = 0; check();
    endtask

    task automatic write_chunk(input xlen_t address, input xlen_t value, input int bytes,
                               input bit error = 0);
        xlen_t data;
        logic [DBUS_BYTES-1:0] strb;
        int lane;
        retire_id_t id;
        lane = int'(address % DBUS_BYTES);
        data = value << (8*lane);
        strb = DBUS_BYTES'(((1 << bytes)-1) << lane);
        id = retire_id_t'(serial++);
        request_store(address, data, strb, id);
        response(id, error);
        repeat (3) begin tick(); check(); end
        retire(id, address, data, strb, error);
    endtask

    // 负向用例每次独立运行；专测脚本只接受指定 STORE_MONITOR_*，不能把超时算通过。
    task automatic run_negative;
        retire_id_t id, wrong_id;
        id = retire_id_t'(1); wrong_id = id; wrong_id.generation ^= 1'b1;
        if (negative_case != 2 && negative_case != 5)
            request_store(result_addr, xlen_t'(1), '1, id);
        unique case (negative_case)
            1: begin dmem_store_fire = 1; store_request_id = wrong_id; end
            2: begin store_response_fire = 1; store_response_id = id; end
            3: begin store_response_fire = 1; store_response_id = wrong_id; end
            4: begin response(id); store_response_fire = 1; store_response_id = id; end
            5: begin store_retire_fire = 1; store_retire_id = id; end
            6: begin response(id); store_retire_fire = 1; store_retire_id = wrong_id; end
            7: begin store_retire_fire = 1; store_retire_id = id; end
            8: begin response(id, 1); store_retire_fire = 1; store_retire_id = id; end
            9: begin cancel = 1; tick(); cancel = 0; store_response_fire = 1; store_response_id = id; end
            10: begin reset_monitor(); store_response_fire = 1; store_response_id = id; end
            11: begin
                response(id); retire(id, result_addr, xlen_t'(1), '1);
                store_retire_fire = 1; store_retire_id = id;
            end
            12: begin
                cancel = 1; tick(); cancel = 0;
                request_store(result_addr, xlen_t'(1), '1, wrong_id);
                store_response_fire = 1; store_response_id = id;
            end
            13: begin cancel = 1; dmem_store_fire = 1; end
            14: begin
                wrong_id = id; wrong_id.slot ^= 1'b1;
                store_response_fire = 1; store_response_id = wrong_id;
            end
            15: begin
                response(id); wrong_id = id; wrong_id.slot ^= 1'b1;
                store_retire_fire = 1; store_retire_id = wrong_id;
            end
            default: $fatal(1, "UNEXPECTED_NEGATIVE_CASE");
        endcase
        tick();
        $fatal(1, "UNEXPECTED_NEGATIVE_ACCEPTANCE case=%0d", negative_case);
    endtask

    initial begin
        result_addr = xlen_t'(32'h1000);
        reset_monitor();
        if ($value$plusargs("NEG_CASE=%d", negative_case)) run_negative();

        // 非目标地址、零报告与半字节均不应提前终止；低/高半可按任意顺序退休。
        write_chunk(result_addr + xlen_t'(16), xlen_t'(1), 4);
        for (int i = 0; i < RESULT_BYTES; i++) write_chunk(result_addr + xlen_t'(i), 0, 1);
        assert (!test_done) else $fatal(1, "UNEXPECTED_ZERO_TERMINATION");
        write_chunk(result_addr, xlen_t'(1), 1);
        assert (!test_done) else $fatal(1, "UNEXPECTED_ZERO_FRAME_REUSE");
        for (int i = 1; i < RESULT_BYTES; i++) write_chunk(result_addr + xlen_t'(i), 0, 1);
        assert (test_done && test_pass) else $fatal(1, "UNEXPECTED_BYTE_ASSEMBLY");

        reset_monitor();
        if (RESULT_BYTES == 8) begin
            write_chunk(result_addr, xlen_t'(1), 4);
            assert (!test_done) else $fatal(1, "UNEXPECTED_LOW_HALF_PASS");
            // 非结果写和无在途写的重定向不能抹掉已退休的低半字。
            write_chunk(result_addr + xlen_t'(32), 0, 4);
            cancel = 1; tick(); cancel = 0; check();
            write_chunk(result_addr + xlen_t'(4), 0, 4);
            assert (test_pass) else $fatal(1, "UNEXPECTED_HIGH_HALF_LOSS");
        end else write_chunk(result_addr, xlen_t'(1), 4);

        reset_monitor();
        if (RESULT_BYTES == 8) write_chunk(result_addr + xlen_t'(4), 0, 4);
        write_chunk(result_addr, xlen_t'(7), 4);
        assert (test_done && !test_pass && test_code == 7) else $fatal(1, "UNEXPECTED_FAIL_CODE");

        // RV64 的高四字节结果地址、一次 SD、非零高半字也由独立绝对地址模型检查。
        if (XLEN == 64) begin
            reset_monitor(); result_addr = xlen_t'(32'h1004);
            for (int i = 0; i < RESULT_BYTES; i++) write_chunk(result_addr + xlen_t'(i), i == 0 ? 1 : 0, 1);
            assert (test_pass) else $fatal(1, "UNEXPECTED_HIGH_LANE_ASSEMBLY");
            result_addr = xlen_t'(32'h1000); reset_monitor();
            write_chunk(result_addr, xlen_t'(1), 8);
            assert (test_pass) else $fatal(1, "UNEXPECTED_SD_ASSEMBLY");
        end
        if (RESULT_BYTES == 8) begin
            reset_monitor();
            write_chunk(result_addr + xlen_t'(4), xlen_t'(1), 4);
            write_chunk(result_addr, xlen_t'(1), 4);
            assert (test_done && !test_pass) else $fatal(1, "UNEXPECTED_UPPER_BITS_IGNORED");

            // 旧零帧不能提供新帧的高半字，低 1 必须等本次高 0 成功退休。
            reset_monitor();
            write_chunk(result_addr, 0, 4);
            write_chunk(result_addr + xlen_t'(4), 0, 4);
            write_chunk(result_addr, xlen_t'(1), 4);
            assert (!test_done) else $fatal(1, "UNEXPECTED_PREVIOUS_ZERO_HIGH_REUSE");
            repeat (5) begin tick(); check(); end
            write_chunk(result_addr + xlen_t'(4), 0, 4);
            assert (test_pass) else $fatal(1, "UNEXPECTED_NEW_FRAME_INCOMPLETE");

            // 另一轮高半失败：不能在错误到来前 PASS，也不能把失败帧低半借给后续重试。
            reset_monitor();
            if (XLEN == 64) write_chunk(result_addr, 0, 8);
            else begin write_chunk(result_addr, 0, 4); write_chunk(result_addr + xlen_t'(4), 0, 4); end
            write_chunk(result_addr, xlen_t'(1), 4);
            assert (!test_done) else $fatal(1, "UNEXPECTED_PASS_BEFORE_HIGH_FAULT");
            write_chunk(result_addr + xlen_t'(4), 0, 4, 1);
            assert (!test_done) else $fatal(1, "UNEXPECTED_HIGH_FAULT_PASS");
            write_chunk(result_addr + xlen_t'(4), 0, 4);
            assert (!test_done) else $fatal(1, "UNEXPECTED_FAILED_FRAME_LOW_REUSE");
            write_chunk(result_addr, xlen_t'(1), 4);
            assert (test_pass) else $fatal(1, "UNEXPECTED_FRAME_RETRY_FAILURE");
        end

        // 同一总线字由两笔互补非连续掩码覆盖；未使能字节故意带垃圾数据。
        reset_monitor();
        for (int offset = 0; offset < RESULT_BYTES; offset += DBUS_BYTES) begin
            request_store(result_addr + xlen_t'(offset),
                          offset == 0 ? xlen_t'(64'ha500_a500_a500_a501) : xlen_t'(64'ha500_a500_a500_a500),
                          DBUS_BYTES'(8'h55), retire_id_t'(serial));
            response(retire_id_t'(serial));
            retire(retire_id_t'(serial++), result_addr + xlen_t'(offset),
                   offset == 0 ? xlen_t'(64'ha500_a500_a500_a501) : xlen_t'(64'ha500_a500_a500_a500),
                   DBUS_BYTES'(8'h55));
            assert (!test_done) else $fatal(1, "UNEXPECTED_MASK_HOLE_PASS");
            request_store(result_addr + xlen_t'(offset), 0, DBUS_BYTES'(8'haa), retire_id_t'(serial));
            response(retire_id_t'(serial));
            retire(retire_id_t'(serial++), result_addr + xlen_t'(offset), 0, DBUS_BYTES'(8'haa));
        end
        assert (test_pass) else $fatal(1, "UNEXPECTED_MASK_ASSEMBLY");

        // 错误响应只能异常退休；失败结果写丢弃本报告所有残片，后续必须重新完整写入。
        reset_monitor();
        write_chunk(result_addr, xlen_t'(1), 1);
        write_chunk(result_addr + xlen_t'(1), 0, 1, 1);
        for (int i = 1; i < RESULT_BYTES; i++) write_chunk(result_addr + xlen_t'(i), 0, 1);
        assert (!test_done) else $fatal(1, "UNEXPECTED_FAILED_FRAGMENT_REUSE");
        write_chunk(result_addr, xlen_t'(1), 1);
        assert (test_pass) else $fatal(1, "UNEXPECTED_RETRY_FAILURE");

        // 取消已收到成功响应、但还没退休的写；普通地址异常可直接异常退休。
        reset_monitor();
        request_store(result_addr, xlen_t'(1), '1, retire_id_t'(10));
        response(retire_id_t'(10));
        cancel = 1; tick(); cancel = 0; check();
        store_retire_fire = 1; store_retire_error = 1; store_retire_id = retire_id_t'(12);
        tick(); store_retire_fire = 0; store_retire_error = 0; check();
        request_store(result_addr, xlen_t'(1), '1, retire_id_t'(11));
        reset_monitor(); check();

        // 响应与退休可以同沿，但取消仍优先于产生测试成功。
        request_store(result_addr, xlen_t'(1), '1, retire_id_t'(13));
        store_response_fire = 1; store_response_id = retire_id_t'(13);
        store_retire_fire = 1; store_retire_id = retire_id_t'(13);
        cancel = 1;
        tick(); store_response_fire = 0; store_retire_fire = 0; cancel = 0; check();
        request_store(result_addr, xlen_t'(1), '1, retire_id_t'(14));
        store_response_fire = 1; store_response_id = retire_id_t'(14);
        store_retire_fire = 1; store_retire_id = retire_id_t'(14);
        reference_commit(result_addr, xlen_t'(1), '1);
        tick(); store_response_fire = 0; store_retire_fire = 0; check();
        if (RESULT_BYTES == 8 && XLEN == 32) write_chunk(result_addr + xlen_t'(4), 0, 4);
        assert (test_pass) else $fatal(1, "UNEXPECTED_RESPONSE_RETIRE_SAME_EDGE");
        reset_monitor();

        // 同沿旧 Store 退休和新 Store 请求，旧结果不能被新请求载荷覆盖。
        request_store(result_addr, xlen_t'(1), DBUS_BYTES'(1), retire_id_t'(20));
        response(retire_id_t'(20));
        store_retire_fire = 1; store_retire_id = retire_id_t'(20);
        reference_commit(result_addr, xlen_t'(1), DBUS_BYTES'(1));
        dmem_store_fire = 1; store_request_id = retire_id_t'(21);
        dmem_store_addr = result_addr + xlen_t'(1); dmem_store_data = 0; dmem_store_strb = DBUS_BYTES'(2);
        tick(); store_retire_fire = 0; dmem_store_fire = 0; check();
        response(retire_id_t'(21));
        retire(retire_id_t'(21), result_addr + xlen_t'(1), 0, DBUS_BYTES'(2));
        for (int i = 2; i < RESULT_BYTES; i++) write_chunk(result_addr + xlen_t'(i), 0, 1);
        assert (test_pass) else $fatal(1, "UNEXPECTED_SAME_EDGE_REPLACEMENT");

        $display("PASS tb_store_result_monitor RV%0d result_bytes=%0d checks=%0d", XLEN, RESULT_BYTES, checks);
        $finish;
    end
endmodule
