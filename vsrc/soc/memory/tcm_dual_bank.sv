// Module: tcm_dual_bank
// Description: Two interleaved synchronous RAM banks shared fairly by native IF64, two data ports and DMA.
module tcm_dual_bank #(
    parameter int unsigned BYTES = soc_config_pkg::ITCM_BYTES,
    parameter INIT_FILE = ""
) (
    input logic clk, rst,
    input logic [3:0] req_valid,
    output logic [3:0] req_ready,
    input bus_types_pkg::bus_req_t request [4],
    output logic [3:0] rsp_valid,
    input logic [3:0] rsp_ready,
    output logic [63:0] rsp_data [4]
);
    import core_config_pkg::*;
    localparam int BYTE_W = $clog2(DBUS_BYTES);
    localparam int WORDS = BYTES / (2 * DBUS_BYTES);
    localparam int INDEX_W = $clog2(WORDS);
    logic [1:0] bank_valid_q, bank_fire;
    logic [1:0] bank_owner_q [2], selected [2], next_q;
    logic [1:0] needed [4];
    logic [XLEN-1:0] bank_data [2];
    logic [3:0] request_fire;
    logic [3:0] buffer_valid_q, direct_valid;
    logic [63:0] buffer_data_q [4], direct_data [4];
    logic [3:0] bank_grant [2];
    logic [1:0] first_selected;

    for (genvar c = 0; c < 4; c++) begin : g_bank_mask
        if (c == 0 && XLEN == 32) begin : g_if_pair
            assign needed[c] = 2'b11;
        end else begin : g_one_word
            assign needed[c] = request[c].addr[BYTE_W] ? 2'b10 : 2'b01;
        end
    end
    // 同步 RAM 的输出只保留一拍归属。反压数据移入客户端缓冲，不能占住共享 bank，
    // 否则满 IF 队列可能堵住解除流水停顿所需的 D Load，形成互相等待。
    always_comb begin
        direct_valid = 0;
        for (int c = 0; c < 4; c++) direct_data[c] = 0;
        for (int b = 0; b < 2; b++) begin
            if (bank_valid_q[b]) begin
                direct_valid[bank_owner_q[b]] = 1;
                if (XLEN == 32 && bank_owner_q[b] == 0)
                    direct_data[0][32*b +: 32] = 32'(bank_data[b]);
                else direct_data[bank_owner_q[b]] = 64'(bank_data[b]);
            end
        end
    end
    assign rsp_valid = direct_valid | buffer_valid_q;
    for (genvar c = 0; c < 4; c++) begin : g_response_buffer
        assign rsp_data[c] = buffer_valid_q[c] ? buffer_data_q[c] : direct_data[c];
        always_ff @(posedge clk) begin
            if (rst) buffer_valid_q[c] <= 0;
            else begin
                if (rsp_ready[c]) buffer_valid_q[c] <= 0;
                if (direct_valid[c] && !rsp_ready[c]) begin
                    buffer_valid_q[c] <= 1; buffer_data_q[c] <= direct_data[c];
                end
            end
        end
    end
    tcm_bank_arbiter u_arbiter (
        .rst, .req_valid, .rsp_valid, .rsp_ready, .needed, .next_q,
        .req_ready, .bank_grant, .bank_fire, .selected, .first_selected
    );
    assign request_fire = req_valid & req_ready;
    always_ff @(posedge clk) begin
        if (rst) begin
            bank_valid_q <= 0; next_q <= 0;
            bank_owner_q[0] <= 0; bank_owner_q[1] <= 0;
        end else begin
            if (|request_fire) next_q <= first_selected + 2'd1;
            bank_valid_q <= bank_fire;
            for (int b = 0; b < 2; b++) begin
                if (bank_fire[b]) bank_owner_q[b] <= selected[b];
            end
        end
    end
    for (genvar b = 0; b < 2; b++) begin : g_bank
        logic [XLEN-1:0] mem [WORDS];
        logic [INDEX_W-1:0] index;
        bus_types_pkg::bus_req_t access;
        // 载荷由互斥 one-hot 掩码直接选择，不再经过二进制 winner 编码再解码。
        always_comb begin
            access = '0;
            for (int c = 0; c < 4; c++)
                access |= request[c] & {$bits(bus_types_pkg::bus_req_t){bank_grant[b][c]}};
        end
        assign index = access.addr[BYTE_W+1 +: INDEX_W];
        initial begin
            if (INIT_FILE != "")
                $readmemh({INIT_FILE, b == 0 ? ".bank0" : ".bank1"}, mem);
        end
        // 每个物理 bank 仅一个同步读写口，不复位 RAM；同 bank 请求由上面的仲裁串行化。
        always_ff @(posedge clk) begin
            if (bank_fire[b]) begin
                bank_data[b] <= mem[index];
                if (access.write)
                    for (int byte_no = 0; byte_no < DBUS_BYTES; byte_no++)
                        if (access.wstrb[byte_no])
                            mem[index][8*byte_no +: 8] <= access.wdata[8*byte_no +: 8];
            end
        end
    end
`ifndef SYNTHESIS
    for (genvar b = 0; b < 2; b++) begin : g_check_grant
        always_ff @(posedge clk) if (!rst)
            assert ($onehot0(bank_grant[b])) else $fatal(1, "TCM bank grant is not one-hot");
    end
    task automatic load_image(input string path);
        logic [XLEN-1:0] words [2*WORDS];
        $readmemh(path, words);
        for (int idx = 0; idx < WORDS; idx++) begin
            g_bank[0].mem[idx] = words[2*idx];
            g_bank[1].mem[idx] = words[2*idx+1];
        end
    endtask
    always_ff @(posedge clk) if (!rst)
        assert ((direct_valid & buffer_valid_q) == 0) else $fatal(1, "TCM client response overrun");
    always_ff @(posedge clk) if (!rst && XLEN == 32)
        assert (!(bank_valid_q[0] && bank_owner_q[0] == 0) ||
                (bank_valid_q[1] && bank_owner_q[1] == 0))
            else $fatal(1, "IF64 bank ownership split");
`endif
endmodule

// Module: tcm_bank_arbiter
// Description: Two-bank round-robin packing with parallel first/disjoint-second selection.
module tcm_bank_arbiter (
    input logic rst,
    input logic [3:0] req_valid, rsp_valid, rsp_ready,
    input logic [1:0] needed [4],
    input logic [1:0] next_q,
    output logic [3:0] req_ready,
    output logic [3:0] bank_grant [2],
    output logic [1:0] bank_fire,
    output logic [1:0] selected [2],
    output logic [1:0] first_selected
);
    logic [3:0] eligible, first_grant, second_grant;
    logic [3:0] compatible [4], second_for_first [4];
    logic [3:0] higher_priority [4];
    logic [1:0] rank [4];
    // 两个物理 bank 最多接纳两个请求。为每个可能首选并行预选不冲突的次选，
    // 首选确定后直接挑选结果，避免首选 bank 掩码再串行驱动第二次仲裁。
    // 与逐项 greedy 的选择完全相同；IF64 需要两 bank，不能拆成两个独立仲裁器。
    for (genvar c = 0; c < 4; c++) begin : g_priority
        assign rank[c] = 2'(c) - next_q;
        assign eligible[c] = req_valid[c] && !rst && (!rsp_valid[c] || rsp_ready[c]);
        for (genvar other = 0; other < 4; other++) begin : g_precedes
            assign higher_priority[c][other] = rank[other] < rank[c];
        end
        assign first_grant[c] = eligible[c] && !(|(eligible & higher_priority[c]));
        for (genvar first = 0; first < 4; first++) begin : g_second_candidate
            assign compatible[first][c] = eligible[c] && ((needed[c] & needed[first]) == 0);
            assign second_for_first[first][c] = compatible[first][c] &&
                !(|(compatible[first] & higher_priority[c]));
        end
        always_comb begin
            second_grant[c] = 1'b0;
            for (int first = 0; first < 4; first++)
                second_grant[c] |= first_grant[first] && second_for_first[first][c];
        end
    end
    always_comb begin
        first_selected = '0;
        for (int c = 0; c < 4; c++) begin
            first_selected |= 2'(c) & {2{first_grant[c]}};
        end
    end
    assign req_ready = first_grant | second_grant;
    for (genvar b = 0; b < 2; b++) begin : g_bank_grant
        for (genvar c = 0; c < 4; c++) begin : g_client
            assign bank_grant[b][c] = req_ready[c] && needed[c][b];
        end
        assign bank_fire[b] = |bank_grant[b];
        always_comb begin
            selected[b] = '0;
            for (int c = 0; c < 4; c++)
                selected[b] |= 2'(c) & {2{bank_grant[b][c]}};
        end
    end
endmodule
