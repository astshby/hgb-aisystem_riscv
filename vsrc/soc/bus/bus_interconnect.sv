// Module: bus_interconnect
// Description: Parameterized per-target round-robin fabric with one outstanding request per master.
module bus_interconnect #(
    parameter int unsigned MASTERS = 2,
    parameter logic [14:0] PRESENT = 15'h000f,
    parameter bit DATA_PRIORITY = 1'b0,
    parameter int unsigned DDR_BYTES = 0
) (
    input logic clk, rst,
    input logic [MASTERS-1:0] m_req_valid,
    output logic [MASTERS-1:0] m_req_ready,
    input bus_types_pkg::bus_req_t m_request [MASTERS],
    output logic [MASTERS-1:0] m_rsp_valid,
    input logic [MASTERS-1:0] m_rsp_ready,
    output bus_types_pkg::bus_rsp_t m_response [MASTERS],
    output logic [14:0] s_req_valid,
    input logic [14:0] s_req_ready,
    output bus_types_pkg::bus_req_t s_request [15],
    output bus_types_pkg::bus_error_e s_error [15],
    input logic [14:0] s_rsp_valid,
    output logic [14:0] s_rsp_ready,
    input bus_types_pkg::bus_rsp_t s_response [15]
);
    import bus_types_pkg::*;
    localparam int OWNER_W = $clog2(MASTERS);
    bus_target_e decoded [MASTERS], route [MASTERS];
    bus_error_e decode_error [MASTERS], route_error [MASTERS];
    logic [MASTERS-1:0] pending_q, master_done;
    logic [14:0] busy_q, locked_q;
    logic [OWNER_W-1:0] owner_q [15], next_q [15], locked_owner_q [15];
    logic [14:0] response_done, grant_valid;
    logic [OWNER_W-1:0] grant_owner [15];
    logic [MASTERS-1:0] eligible [15];
    logic [14:0] data_ready, dma_turn;

    for (genvar m = 0; m < MASTERS; m++) begin : g_decode
        address_decode #(.DDR_BYTES(DDR_BYTES)) u_decode (
            .request(m_request[m]), .target(decoded[m]), .error(decode_error[m])
        );
        always_comb begin
            route[m] = decoded[m];
            route_error[m] = decode_error[m];
            if (decode_error[m] != BUS_OK || !PRESENT[decoded[m]]) begin
                route[m] = TARGET_ERROR;
                if (decode_error[m] == BUS_OK)
                    route_error[m] = BUS_DECERR;
            end
        end
    end

    // 响应沿接受请求时保存的 owner 返回，不能用当前地址重新译码。
    always_comb begin
        m_rsp_valid = '0;
        for (int m = 0; m < MASTERS; m++) m_response[m] = '0;
        s_rsp_ready = '0;
        for (int s = 0; s < 15; s++) begin
            if (busy_q[s]) begin
                m_rsp_valid[owner_q[s]] = s_rsp_valid[s];
                m_response[owner_q[s]] = s_response[s];
                s_rsp_ready[s] = m_rsp_ready[owner_q[s]];
            end
        end
    end
    assign response_done = s_rsp_valid & s_rsp_ready;
    assign master_done = m_rsp_valid & m_rsp_ready;

    for (genvar s = 0; s < 15; s++) begin : g_eligibility
        for (genvar m = 0; m < MASTERS; m++) begin : g_master
            assign eligible[s][m] = m_req_valid[m] && (int'(route[m]) == s) &&
                (!pending_q[m] || master_done[m]) &&
                (!DATA_PRIORITY || !busy_q[s] || owner_q[s] == OWNER_W'(m));
        end
        // D-ready 独立于 I-valid，不能从同时包含两个候选的组合块回推。
        if (MASTERS > 2) begin : g_dma_turn
            assign dma_turn[s] = eligible[s][2] && next_q[s] == OWNER_W'(2);
        end else begin : g_two_masters
            assign dma_turn[s] = 1'b0;
        end
        assign data_ready[s] = eligible[s][1] && !dma_turn[s] &&
                               (!locked_q[s] || locked_owner_q[s] == OWNER_W'(1)) &&
                               (!busy_q[s] || response_done[s]) && s_req_ready[s];
    end

    // 不同 bank 并行；同一 bank 轮询。被从端反压后锁住选择，防止请求载荷变化。
    always_comb begin
        int candidate;
        candidate = 0;
        grant_valid = '0;
        s_req_valid = '0;
        for (int s = 0; s < 15; s++) begin
            grant_owner[s] = '0;
            s_request[s] = '0;
            s_error[s] = BUS_OK;
            if (!busy_q[s] || response_done[s]) begin
                grant_valid[s] = |eligible[s];
                for (int offset = MASTERS-1; offset >= 0; offset--) begin
                    candidate = int'(next_q[s]) + offset;
                    if (candidate >= MASTERS) candidate -= MASTERS;
                    if (eligible[s][candidate]) grant_owner[s] = OWNER_W'(candidate);
                end
                // CPU D 胜过 IF，但与 DMA 轮流访问同一目标，避免持续访存饿死 DMA。
                if (DATA_PRIORITY && eligible[s][1] && grant_owner[s] == OWNER_W'(0))
                    grant_owner[s] = OWNER_W'(1);
                // IF 可撤回未接受请求；CPU 模式下撤回在下一沿释放，切断组合反压环。
                if (locked_q[s] && (DATA_PRIORITY || eligible[s][locked_owner_q[s]])) begin
                    grant_valid[s] = eligible[s][locked_owner_q[s]];
                    grant_owner[s] = locked_owner_q[s];
                end
                if (grant_valid[s]) begin
                    s_req_valid[s] = 1'b1;
                    s_request[s] = m_request[grant_owner[s]];
                    s_error[s] = route_error[grant_owner[s]];
                end
            end
        end
    end
    for (genvar m = 0; m < MASTERS; m++) begin : g_ready
        if (DATA_PRIORITY && m == 1) begin : g_data
            assign m_req_ready[m] = |data_ready;
        end else begin : g_arbitrated
            always_comb begin
                m_req_ready[m] = 1'b0;
                for (int s = 0; s < 15; s++)
                    if (grant_valid[s] && grant_owner[s] == OWNER_W'(m))
                        m_req_ready[m] = s_req_ready[s];
            end
        end
    end

    // 旧响应与新请求同拍握手时，新请求的 owner/在途位优先，保持一拍 RAM 吞吐。
    always_ff @(posedge clk) begin
        if (rst) begin
            pending_q <= '0;
            busy_q <= '0;
            locked_q <= '0;
            for (int s = 0; s < 15; s++) begin
                owner_q[s] <= '0;
                next_q[s] <= '0;
                locked_owner_q[s] <= '0;
            end
        end else begin
            pending_q <= pending_q & ~master_done;
            busy_q <= busy_q & ~response_done;
            for (int s = 0; s < 15; s++) begin
                locked_q[s] <= s_req_valid[s] && !s_req_ready[s];
                locked_owner_q[s] <= grant_owner[s];
                if (s_req_valid[s] && s_req_ready[s]) begin
                    pending_q[grant_owner[s]] <= 1'b1;
                    busy_q[s] <= 1'b1;
                    owner_q[s] <= grant_owner[s];
                    next_q[s] <= grant_owner[s] == OWNER_W'(MASTERS-1) ?
                                 '0 : grant_owner[s] + OWNER_W'(1);
                end
            end
        end
    end
endmodule
