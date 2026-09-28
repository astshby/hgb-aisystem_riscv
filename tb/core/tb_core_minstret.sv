// Module: tb_core_minstret
// Description: Checks ordered retirement-counter reads and writes against an independent commit model.
module tb_core_minstret;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import riscv_priv_pkg::*;
    import rv_asm_pkg::*;

    logic clk = 1'b0, rst = 1'b1;
    logic imem_req_valid, imem_req_ready, imem_rsp_valid, imem_rsp_ready;
    xlen_t imem_req_addr;
    logic [31:0] imem_rsp_data;
    logic imem_rsp_error = 1'b0, dmem_rsp_error = 1'b0;
    logic dmem_req_valid, dmem_req_ready, dmem_req_write;
    mem_size_e dmem_req_size;
    xlen_t dmem_req_addr, dmem_req_wdata, dmem_rsp_rdata;
    logic [DBUS_BYTES-1:0] dmem_req_wstrb;
    logic dmem_rsp_valid, dmem_rsp_ready;
    logic commit_valid, commit_rd_we, commit_exception;
    xlen_t commit_pc, commit_rd_data;
    logic [31:0] commit_inst;
    gpr_addr_t commit_rd;
    logic pending_q;
    int delay_q, requests, cursor, checks, traps;
    logic [63:0] reference_count;
    xlen_t registers [32];
    xlen_t counter_old, operand, counter_new, end_pc;
    logic counter_access, counter_write, done;
    always #5 clk = ~clk;

    core dut (.fence_i_commit(), .irq_software(1'b0), .irq_timer(1'b0), .irq_external(1'b0), .*);
    sim_imem #(.DEPTH_WORDS(256)) u_imem (
        .clk, .rst, .req_valid(imem_req_valid), .req_addr(imem_req_addr),
        .req_ready(imem_req_ready), .rsp_valid(imem_rsp_valid),
        .rsp_data(imem_rsp_data), .rsp_ready(imem_rsp_ready)
    );

    // 真实请求握手后延迟完成，覆盖计数器前方 Load/Store 的长等待和发射去重。
    assign dmem_req_ready = !pending_q && (!dmem_rsp_valid || dmem_rsp_ready);
    always_ff @(posedge clk) begin
        if (rst) begin
            pending_q <= 1'b0;
            dmem_rsp_valid <= 1'b0;
            dmem_rsp_rdata <= '0;
            delay_q <= 0;
            requests <= 0;
        end else begin
            if (dmem_rsp_valid && dmem_rsp_ready) dmem_rsp_valid <= 1'b0;
            if (pending_q) begin
                if (delay_q == 0) begin
                    pending_q <= 1'b0;
                    dmem_rsp_valid <= 1'b1;
                    dmem_rsp_rdata <= 63;
                end else delay_q <= delay_q - 1;
            end
            if (dmem_req_valid && dmem_req_ready) begin
                requests <= requests + 1;
                pending_q <= 1'b1;
                delay_q <= 7;
            end
        end
    end

    // 仅由架构退休流建立 64 位参考计数，不读取 DUT 内部 CSR 或采用固定流水补偿。
    always @(posedge clk) begin
        if (rst) begin
            reference_count = 0;
            checks = 0;
            traps = 0;
            done = 0;
            for (int r = 0; r < 32; r++) registers[r] = '0;
        end else if (commit_valid) begin
            if (commit_exception) begin
                assert (commit_inst == enc_ecall()) else $fatal(1, "unexpected counter-test trap");
                traps++;
            end else begin
                counter_access = commit_inst[6:0] == 7'h73 && commit_inst[14:12] != 0 &&
                                 (commit_inst[31:20] == CSR_MINSTRET ||
                                  (XLEN == 32 && commit_inst[31:20] == CSR_MINSTRETH));
                counter_write = 1'b0;
                if (counter_access) begin
                    counter_old = (commit_inst[31:20] == CSR_MINSTRETH) ?
                                  xlen_t'(reference_count >> 32) : xlen_t'(reference_count);
                    if (commit_rd_we) begin
                        assert (commit_rd_data == counter_old)
                            else $fatal(1, "counter PC=%h got=%h expected=%h", commit_pc,
                                        commit_rd_data, counter_old);
                        checks++;
                    end
                    operand = commit_inst[14] ? xlen_t'(commit_inst[19:15]) : registers[commit_inst[19:15]];
                    counter_write = commit_inst[13:12] == 2'b01 || commit_inst[19:15] != 0;
                    case (commit_inst[13:12])
                        2'b01: counter_new = operand;
                        2'b10: counter_new = counter_old | operand;
                        default: counter_new = counter_old & ~operand;
                    endcase
                    if (counter_write) begin
                        if (XLEN == 64) reference_count = 64'(counter_new);
                        else if (commit_inst[31:20] == CSR_MINSTRETH)
                            reference_count[63:32] = counter_new[31:0];
                        else reference_count[31:0] = counter_new[31:0];
                    end
                end
                if (!counter_write) reference_count++;
                if (commit_rd_we && commit_rd != 0) registers[commit_rd] = commit_rd_data;
                if (commit_pc == end_pc) done = 1'b1;
            end
        end
    end

    task automatic emit(input logic [31:0] inst);
        u_imem.mem[cursor] = inst;
        cursor++;
    endtask

    initial begin
        for (int i = 0; i < 256; i++) u_imem.mem[i] = nop();
        cursor = 0;
        emit(enc_addi(1, 0, 512));
        emit(enc_csrrw(0, CSR_MTVEC, 1));
        // 无间隔、一个及多个 NOP；读计数器本身也应影响下一次读取。
        for (int gap = 0; gap < 6; gap++) begin
            emit(enc_csrrwi(0, CSR_MINSTRET, 0));
            for (int i = 0; i < gap; i++) emit(nop());
            emit(enc_csrrs(5, CSR_MINSTRET, 0));
            emit(enc_csrrs(6, CSR_MINSTRET, 0));
        end
        emit(enc_lw(2, 0, 768));
        emit(enc_csrrs(5, CSR_MINSTRET, 0));
        emit(enc_sw(2, 0, 768));
        emit(enc_csrrs(5, CSR_MINSTRET, 0));
        emit(enc_addi(3, 0, 7));
        emit(enc_div(4, 2, 3));
        emit(enc_csrrs(5, CSR_MINSTRET, 0));
        emit(enc_csrrsi(5, CSR_MINSTRET, 2));
        emit(enc_csrrci(5, CSR_MINSTRET, 1));
        emit(enc_csrrwi(5, CSR_MINSTRET, 3));
        emit(enc_csrrs(5, CSR_MINSTRET, 0));
        if (XLEN == 32) begin
            emit(enc_addi(1, 0, -1));
            emit(enc_csrrw(0, CSR_MINSTRET, 1));
            emit(enc_csrrwi(0, CSR_MINSTRETH, 0));
            emit(nop());
            emit(enc_csrrs(5, CSR_MINSTRETH, 0));
            emit(enc_csrrs(6, CSR_MINSTRET, 0));
            emit(enc_csrrwi(5, CSR_MINSTRETH, 5));
            emit(enc_csrrs(6, CSR_MINSTRET, 0));
        end
        // ECALL 不计入退休数，handler 与 MRET 正常计数。
        emit(enc_ecall());
        emit(enc_csrrs(5, CSR_MINSTRET, 0));
        end_pc = xlen_t'(cursor * 4);
        emit(enc_jal(0, 0));
        cursor = 128;
        emit(enc_csrrs(20, CSR_MEPC, 0));
        emit(enc_addi(20, 20, 4));
        emit(enc_csrrw(0, CSR_MEPC, 20));
        emit(enc_mret());
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (int cycles = 0; cycles < 1800; cycles++) begin
            @(negedge clk);
            if (done) begin
                assert (checks >= 20 && traps == 1 && requests == 2)
                    else $fatal(1, "counter test coverage or request duplication");
                $display("PASS tb_core_minstret RV%0d checks=%0d traps=%0d requests=%0d", XLEN, checks, traps, requests);
                break;
            end
        end
        if (!done) $fatal(1, "counter program timeout");
        $finish;
    end
endmodule
