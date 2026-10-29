// Module: tcm_bram
// Description: Same-clock dual-port BRAM with a dedicated CPU port and fair auxiliary access.
module tcm_bram #(
    parameter int unsigned BYTES = soc_config_pkg::ITCM_BYTES,
    parameter bit INSTRUCTION = 1,
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
    localparam int PRIMARY = INSTRUCTION ? 0 : 1;
    localparam int BYTE_W = $clog2(DBUS_BYTES);
    localparam int WORDS = BYTES / (2 * DBUS_BYTES);
    localparam int INDEX_W = $clog2(WORDS);
    logic [1:0] needed [4];
    logic [3:0] eligible, direct_valid, buffer_valid_q;
    logic [63:0] direct_data [4], buffer_data_q [4];
    logic [1:0] a_fire, b_fire, a_valid_q, b_valid_q, bank_fire;
    logic [XLEN-1:0] a_data [2], b_data [2];
    logic [1:0] b_owner_q [2], next_q [2], selected [2];
    logic [3:0] candidates [2], grant [2], preceding [2][4];
    logic [1:0] rank [2][4], collision;
    logic primary_grant, auxiliary_turn_q;
    bus_types_pkg::bus_req_t auxiliary [2];

    for (genvar c = 0; c < 4; c++) begin : g_client
        if (c == 0 && XLEN == 32) begin : g_if64
            assign needed[c] = 2'b11;
        end else begin : g_word
            assign needed[c] = request[c].addr[BYTE_W] ? 2'b10 : 2'b01;
        end
        assign eligible[c] = !rst && req_valid[c] && (!rsp_valid[c] || rsp_ready[c]);
        assign rsp_data[c] = buffer_valid_q[c] ? buffer_data_q[c] : direct_data[c];
        always_ff @(posedge clk) begin
            if (rst) buffer_valid_q[c] <= 0;
            else begin
                if (rsp_ready[c]) buffer_valid_q[c] <= 0;
                if (direct_valid[c] && !rsp_ready[c]) begin
                    buffer_valid_q[c] <= 1;
                    buffer_data_q[c] <= direct_data[c];
                end
            end
        end
    end
    assign rsp_valid = direct_valid | buffer_valid_q;

    // A口固定连接取指或第一数据口，地址不经过四客户端选择器。
    // B口在其余请求间按bank轮询，载荷选择不依赖A/B同址冲突的最终许可。
    for (genvar b = 0; b < 2; b++) begin : g_auxiliary
        for (genvar c = 0; c < 4; c++) begin : g_candidate
            assign candidates[b][c] = c != PRIMARY && c != 0 && eligible[c] && needed[c][b];
            assign rank[b][c] = 2'(c) - next_q[b];
            for (genvar other = 0; other < 4; other++) begin : g_precedes
                assign preceding[b][c][other] = rank[b][other] < rank[b][c];
            end
            assign grant[b][c] = candidates[b][c] && !(|(candidates[b] & preceding[b][c]));
        end
        always_comb begin
            auxiliary[b] = '0;
            selected[b] = '0;
            for (int c = 0; c < 4; c++) begin
                auxiliary[b] |= request[c] & {$bits(bus_types_pkg::bus_req_t){grant[b][c]}};
                selected[b] |= 2'(c) & {2{grant[b][c]}};
            end
        end
        // 两读可并行，同字且至少一写时串行，避免依赖器件跨口read-during-write模式。
        assign collision[b] = eligible[PRIMARY] && needed[PRIMARY][b] && (|grant[b]) &&
            request[PRIMARY].addr[BYTE_W+1 +: INDEX_W] == auxiliary[b].addr[BYTE_W+1 +: INDEX_W] &&
            (request[PRIMARY].write || auxiliary[b].write);
        assign a_fire[b] = primary_grant && needed[PRIMARY][b];
        assign b_fire[b] = (|grant[b]) && !(primary_grant && collision[b]);
        always_ff @(posedge clk) begin
            if (rst) begin
                a_valid_q[b] <= 0;
                b_valid_q[b] <= 0;
                b_owner_q[b] <= 0;
                next_q[b] <= 0;
            end else begin
                a_valid_q[b] <= a_fire[b];
                b_valid_q[b] <= b_fire[b];
                if (b_fire[b]) begin
                    b_owner_q[b] <= selected[b];
                    next_q[b] <= selected[b] + 2'd1;
                end
            end
        end
    end
    // IF64只在两个bank都可读时授权。同址持续竞争交替授予A/B，避免辅助口饥饿。
    assign primary_grant = eligible[PRIMARY] && !(auxiliary_turn_q && (|collision));
    always_ff @(posedge clk) begin
        if (rst) auxiliary_turn_q <= 0;
        else if (|collision) auxiliary_turn_q <= !auxiliary_turn_q;
    end
    always_comb begin
        req_ready = '0;
        req_ready[PRIMARY] = primary_grant;
        for (int b = 0; b < 2; b++)
            req_ready |= grant[b] & {4{b_fire[b]}};
    end
    assign bank_fire = a_fire | b_fire;

    // RAM数据下一拍返回；未接收的响应进入客户端私有缓冲，不占住物理bank。
    always_comb begin
        direct_valid = '0;
        for (int c = 0; c < 4; c++) direct_data[c] = '0;
        for (int b = 0; b < 2; b++) begin
            if (a_valid_q[b]) begin
                direct_valid[PRIMARY] = 1;
                if (INSTRUCTION && XLEN == 32) direct_data[PRIMARY][32*b +: 32] = 32'(a_data[b]);
                else direct_data[PRIMARY] = 64'(a_data[b]);
            end
            if (b_valid_q[b]) begin
                direct_valid[b_owner_q[b]] = 1;
                direct_data[b_owner_q[b]] = 64'(b_data[b]);
            end
        end
    end
    for (genvar b = 0; b < 2; b++) begin : g_bank
        logic [XLEN-1:0] mem [WORDS];
        logic [INDEX_W-1:0] a_index, b_index;
        assign a_index = request[PRIMARY].addr[BYTE_W+1 +: INDEX_W];
        assign b_index = auxiliary[b].addr[BYTE_W+1 +: INDEX_W];
        initial begin
            if (INIT_FILE != "") $readmemh({INIT_FILE, b == 0 ? ".bank0" : ".bank1"}, mem);
        end
        // 同一时钟的真正双端口同步读写；不复位RAM。冲突已在许可端串行化。
        always_ff @(posedge clk) begin
            if (a_fire[b]) begin
                a_data[b] <= mem[a_index];
                for (int lane = 0; lane < DBUS_BYTES; lane++)
                    if (request[PRIMARY].write && request[PRIMARY].wstrb[lane])
                        mem[a_index][8*lane +: 8] <= request[PRIMARY].wdata[8*lane +: 8];
            end
        end
        always_ff @(posedge clk) begin
            if (b_fire[b]) begin
                b_data[b] <= mem[b_index];
                for (int lane = 0; lane < DBUS_BYTES; lane++)
                    if (auxiliary[b].write && auxiliary[b].wstrb[lane])
                        mem[b_index][8*lane +: 8] <= auxiliary[b].wdata[8*lane +: 8];
            end
        end
    end
`ifndef SYNTHESIS
    task automatic load_image(input string path);
        logic [XLEN-1:0] words [2*WORDS];
        $readmemh(path, words);
        for (int index = 0; index < WORDS; index++) begin
            g_bank[0].mem[index] = words[2*index];
            g_bank[1].mem[index] = words[2*index+1];
        end
    endtask
    always_ff @(posedge clk) if (!rst) begin
        assert ((direct_valid & buffer_valid_q) == 0) else $fatal(1, "BRAM response overrun");
        assert (INSTRUCTION || !req_valid[0]) else $fatal(1, "DTCM has no instruction port");
        if (INSTRUCTION && XLEN == 32)
            assert (a_fire == 0 || a_fire == 3) else $fatal(1, "split IF64 request");
        for (int b = 0; b < 2; b++) begin
            assert ($onehot0(grant[b])) else $fatal(1, "BRAM auxiliary grant not one-hot");
            assert (!(a_fire[b] && b_fire[b] && collision[b])) else $fatal(1, "BRAM write collision");
        end
    end
`endif
endmodule
