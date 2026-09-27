// Module: bus_interconnect
// Description: Two-master per-target round-robin fabric with one outstanding request per master.
module bus_interconnect #(
    parameter logic [14:0] PRESENT = 15'h000f,
    parameter int unsigned DDR_BYTES = 0
) (
    input logic clk, rst,
    input logic [1:0] m_req_valid,
    output logic [1:0] m_req_ready,
    input bus_types_pkg::bus_req_t m_request [2],
    output logic [1:0] m_rsp_valid,
    input logic [1:0] m_rsp_ready,
    output bus_types_pkg::bus_rsp_t m_response [2],
    output logic [14:0] s_req_valid,
    input logic [14:0] s_req_ready,
    output bus_types_pkg::bus_req_t s_request [15],
    output bus_types_pkg::bus_error_e s_error [15],
    input logic [14:0] s_rsp_valid,
    output logic [14:0] s_rsp_ready,
    input bus_types_pkg::bus_rsp_t s_response [15]
);
    import bus_types_pkg::*;
    bus_target_e decoded [2], route [2];
    bus_error_e decode_error [2], route_error [2];
    logic [1:0] pending_q, master_done;
    logic [14:0] busy_q, owner_q, next_q, locked_q, locked_owner_q;
    logic [14:0] response_done, grant_valid, grant_owner;
    logic [1:0] eligible [15];

    for (genvar m = 0; m < 2; m++) begin : g_decode
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
        m_response[0] = '0;
        m_response[1] = '0;
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

    // 不同 bank 并行；同一 bank 轮询。被从端反压后锁住选择，防止请求载荷变化。
    always_comb begin
        grant_valid = '0;
        grant_owner = '0;
        s_req_valid = '0;
        for (int s = 0; s < 15; s++) begin
            s_request[s] = '0;
            s_error[s] = BUS_OK;
            for (int m = 0; m < 2; m++)
                eligible[s][m] = m_req_valid[m] && (int'(route[m]) == s) &&
                                 (!pending_q[m] || master_done[m]);
            if (!busy_q[s] || response_done[s]) begin
                grant_valid[s] = |eligible[s];
                grant_owner[s] = eligible[s][next_q[s]] ? next_q[s] : !next_q[s];
                // IF 可撤回未接受请求；锁定者撤回后允许另一主端口接替。
                if (locked_q[s] && eligible[s][locked_owner_q[s]]) begin
                    grant_valid[s] = 1'b1;
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
    always_comb begin
        m_req_ready = '0;
        for (int s = 0; s < 15; s++)
            if (grant_valid[s])
                m_req_ready[grant_owner[s]] = s_req_ready[s];
    end

    // 旧响应与新请求同拍握手时，新请求的 owner/在途位优先，保持一拍 RAM 吞吐。
    always_ff @(posedge clk) begin
        if (rst) begin
            pending_q <= '0;
            busy_q <= '0;
            owner_q <= '0;
            next_q <= '0;
            locked_q <= '0;
            locked_owner_q <= '0;
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
                    next_q[s] <= !grant_owner[s];
                end
            end
        end
    end
endmodule
