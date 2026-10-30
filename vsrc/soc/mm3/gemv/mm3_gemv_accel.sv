// Module: mm3_gemv_accel
// Description: MMIO W8A16 GEMV with exact integer scales, vector-wide requantization and DDR block DMA.
module mm3_gemv_accel #(
    parameter int unsigned DDR_BYTES = 128*1024*1024,
    parameter int unsigned MAC_LANES = mm3_config_pkg::MM3_GEMV_LANES
) (
    input logic clk, rst,
    output logic busy_out,
    output logic irq,
    input logic req_valid,
    output logic req_ready,
    input bus_types_pkg::bus_req_t request,
    output logic rsp_valid,
    input logic rsp_ready,
    output bus_types_pkg::bus_rsp_t response,
    output logic rd_cmd_valid,
    input logic rd_cmd_ready,
    output block_types_pkg::block_cmd_t rd_cmd,
    input logic rd_valid,
    output logic rd_ready,
    input block_types_pkg::block_r_t rd_data,
    output logic wr_cmd_valid,
    input logic wr_cmd_ready,
    output block_types_pkg::block_cmd_t wr_cmd,
    output logic wr_valid,
    input logic wr_ready,
    output block_types_pkg::block_w_t wr_data,
    input logic wr_rsp_valid,
    output logic wr_rsp_ready,
    input block_types_pkg::block_b_t wr_rsp
);
    import mm3_fixed_pkg::*;
    import bus_types_pkg::*;
    import block_types_pkg::*;
    typedef enum logic [5:0] {
        IDLE, VALIDATE, X_START, X_LOAD, S_START, S_LOAD, W_START, W_LOAD, MAC,
        MUL_X_START, MUL_X_WAIT, MUL_W_START, MUL_W_WAIT, MAX_SCALE_START, MAX_SCALE_WAIT,
        PACK_START, PACK_WAIT, WRITE_CMD, WRITE_DATA, WRITE_RESPONSE, SCALE_WRITE, FINISH, FAIL
    } state_e;
    state_e state_q;
    logic [31:0] cfg [10];
    logic done_q, error_q;
    logic [31:0] error_code_q, row_q, col_q, load_q, output_row_q;
    logic [31:0] out_m_q;
    logic signed [31:0] out_e_q;
    logic [63:0] counters [10];
    logic [31:0] read_data, write_data, write_mask;
    logic access_error, access_fire, busy;
    logic signed [15:0] x [2432];
    logic [31:0] row_m [6400];
    logic signed [31:0] row_e [6400];
    fixed_t work [6400];
    fixed_t max_q, scaled_x_q;
    logic signed [63:0] acc_q, mac_sum;
    logic signed [23:0] products [MAC_LANES];
    logic [255:0] weight_q, packed_q;
    logic [5:0] weight_bytes_q, packed_bytes_q;
    logic [31:0] write_addr_q;
    logic scale_write_q;
    logic reader_start, reader_busy, reader_failed, stream_valid, stream_ready, stream_last;
    logic [31:0] reader_addr, reader_bytes;
    logic [255:0] stream_data;
    logic [5:0] stream_count;
    logic math_start, math_divide, math_busy, math_done;
    fixed_t math_a, math_b, math_result;
    logic [63:0] ceil_multiplier, quantized_mag;
    logic signed [31:0] quantized;
    int unsigned take, width_bytes;
    logic [63:0] range_start [5], range_end [5];
    logic bad_config, overlap;
    assign busy = state_q != IDLE;
    assign busy_out = busy;
    // 仅导出既有状态电平，W1C 与算子完成顺序仍由原状态机管理。
    assign irq = done_q || error_q;
    assign width_bytes = cfg[9] != 0 ? 4 : 2;
    mmio_endpoint u_mmio (.*);
    mm3_reader u_reader (
        .clk, .rst, .start(reader_start), .address(reader_addr), .bytes(reader_bytes),
        .busy(reader_busy), .failed(reader_failed), .valid(stream_valid), .ready(stream_ready),
        .data(stream_data), .count(stream_count), .last(stream_last),
        .rd_cmd_valid, .rd_cmd_ready, .rd_cmd, .rd_valid, .rd_ready, .rd_data
    );
    mm3_fixed_math u_math (.clk, .rst, .start(math_start), .divide(math_divide),
        .a(math_a), .b(math_b), .busy(math_busy), .done(math_done), .result(math_result));
    always_comb begin
        read_data = 0; access_error = 0;
        if (request.addr[11:0] >= 12'h014 && request.addr[11:0] <= 12'h038) begin
            read_data = cfg[(int'(request.addr[11:0])-20)/4];
            access_error = request.write && busy;
        end else if (request.addr[11:0] >= 12'h040 && request.addr[11:0] < 12'h090) begin
            read_data = 32'(counters[(int'(request.addr[11:0])-64)/8] >> (request.addr[2] ? 32 : 0));
            access_error = request.write;
        end else begin
            unique case (request.addr[11:0])
                12'h000: begin read_data = 32'h4d330001; access_error = request.write; end
                12'h004: begin read_data = (32'(MAC_LANES) << 25) | (32'd6400 << 12) | 32'd2432; access_error = request.write; end
                12'h008: access_error = !request.write || busy || (write_data & write_mask) != 1;
                12'h00c: begin
                    read_data = {29'b0,error_q,done_q,busy};
                    access_error = request.write && (busy || |(write_data & write_mask & ~32'd6));
                end
                12'h010: begin read_data = error_code_q; access_error = request.write; end
                default: access_error = 1;
            endcase
        end
    end
    // 起止地址用宽整数计算，先检查回绕、权限和重叠，再发出任何外存请求。
    always_comb begin
        range_start[0] = {32'b0,cfg[2]}; range_end[0] = range_start[0]+64'(cfg[1])*2;
        range_start[1] = {32'b0,cfg[3]}; range_end[1] = range_start[1]+64'(cfg[0])*64'(cfg[1]);
        range_start[2] = {32'b0,cfg[4]}; range_end[2] = range_start[2]+64'(cfg[0])*8;
        range_start[3] = {32'b0,cfg[5]}; range_end[3] = range_start[3]+64'(cfg[0])*64'(width_bytes);
        range_start[4] = {32'b0,cfg[6]}; range_end[4] = range_start[4]+8;
        bad_config = cfg[0] == 0 || cfg[0] > 6400 || cfg[1] == 0 || cfg[1] > 2432 || cfg[9] > 1 ||
                     cfg[7] < 32'h40000000 || cfg[7] >= 32'h80000000 || $signed(cfg[8]) < -256 || $signed(cfg[8]) > 256;
        overlap = 0;
        for (int i = 0; i < 5; i++) begin
            bad_config |= range_start[i][5:0] != 0 || range_start[i] < 64'h80000000 ||
                          ((range_end[i]+31) & ~64'd31) > 64'h80000000+64'(DDR_BYTES);
            for (int j = 0; j < i; j++) overlap |= range_start[i] < range_end[j] && range_start[j] < range_end[i];
        end
    end
    for (genvar lane = 0; lane < MAC_LANES; lane++) begin : g_mac_product
        assign products[lane] = (lane < int'(weight_bytes_q) && col_q+32'(lane) < cfg[1]) ?
                                $signed(weight_q[lane*8 +: 8]) * x[col_q+32'(lane)] : 24'sd0;
    end
    always_comb begin
        reader_start = 0; reader_addr = 0; reader_bytes = 0; stream_ready = 0;
        if (state_q == X_START) begin reader_start = 1; reader_addr = cfg[2]; reader_bytes = cfg[1]*2; end
        if (state_q == S_START) begin reader_start = 1; reader_addr = cfg[4]; reader_bytes = cfg[0]*8; end
        if (state_q == W_START && error_code_q == 0) begin reader_start = 1; reader_addr = cfg[3]+row_q*cfg[1]; reader_bytes = cfg[1]; end
        if (state_q == X_LOAD || state_q == S_LOAD || state_q == W_LOAD) stream_ready = 1;
        math_start = 0; math_divide = 0; math_a = '0; math_b = '0;
        if (state_q == MUL_X_START) begin
            math_start = 1; math_a = make_fixed(acc_q,0); math_b = scale_fixed(cfg[7],$signed(cfg[8]));
        end
        if (state_q == MUL_W_START) begin
            math_start = 1; math_a = scaled_x_q; math_b = scale_fixed(row_m[row_q],row_e[row_q]);
        end
        if (state_q == MAX_SCALE_START) begin
            math_start = 1; math_divide = 1; math_a = max_q;
            math_b = make_fixed(cfg[9] != 0 ? 64'sh7fffffff : 64'sh7fff,0);
        end
        if (state_q == PACK_START) begin
            math_start = 1; math_divide = 1; math_a = work[output_row_q]; math_b = scale_fixed(out_m_q,out_e_q);
        end
        take = int'(weight_bytes_q) < MAC_LANES ? int'(weight_bytes_q) : MAC_LANES;
        mac_sum = 0;
        for (int i = 0; i < MAC_LANES; i++)
            if (i < take && col_q+32'(i) < cfg[1])
                mac_sum += 64'(products[i]);
        ceil_multiplier = (magnitude(math_result.v)+64'h3fffffff) >> 30;
        quantized_mag = integer_mag(math_result,cfg[9] != 0);
        quantized = math_result.v < 0 ? -$signed(32'(quantized_mag)) : $signed(32'(quantized_mag));
        wr_cmd_valid = state_q == WRITE_CMD; wr_cmd = '0;
        wr_cmd.addr = core_types_pkg::xlen_t'(write_addr_q); wr_cmd.size = 5;
        wr_valid = state_q == WRITE_DATA; wr_data = '0;
        wr_data.data = packed_q; wr_data.last = 1;
        for (int i = 0; i < 32; i++) wr_data.strb[i] = i < int'(packed_bytes_q);
        wr_rsp_ready = state_q == WRITE_RESPONSE;
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q <= IDLE; done_q <= 0; error_q <= 0; error_code_q <= 0;
            row_q <= 0; col_q <= 0; load_q <= 0; output_row_q <= 0;
            out_m_q <= 0; out_e_q <= 0; max_q <= '0; scaled_x_q <= '0;
            acc_q <= 0; weight_q <= 0; weight_bytes_q <= 0;
            packed_q <= 0; packed_bytes_q <= 0; write_addr_q <= 0; scale_write_q <= 0;
            for (int i = 0; i < 10; i++) begin cfg[i] <= 0; counters[i] <= 0; end
        end else begin
            if (busy) counters[0] <= counters[0]+1;
            if (state_q inside {X_START,X_LOAD,S_START,S_LOAD,W_START,W_LOAD}) counters[1] <= counters[1]+1;
            if (state_q == MAC) counters[2] <= counters[2]+1;
            if (state_q inside {MUL_X_START,MUL_X_WAIT,MUL_W_START,MUL_W_WAIT,MAX_SCALE_START,MAX_SCALE_WAIT}) counters[3] <= counters[3]+1;
            if (state_q inside {PACK_START,PACK_WAIT}) counters[4] <= counters[4]+1;
            if (state_q inside {WRITE_CMD,WRITE_DATA,WRITE_RESPONSE,SCALE_WRITE}) counters[5] <= counters[5]+1;
            if (busy && ((rd_cmd_valid && !rd_cmd_ready) || (rd_ready && !rd_valid))) counters[6] <= counters[6]+1;
            if (busy && ((wr_cmd_valid && !wr_cmd_ready) || (wr_valid && !wr_ready) || (wr_rsp_ready && !wr_rsp_valid))) counters[7] <= counters[7]+1;
            if (access_fire && request.write) begin
                if (request.addr[11:0] >= 12'h014 && request.addr[11:0] <= 12'h038)
                    cfg[(int'(request.addr[11:0])-20)/4] <=
                        (cfg[(int'(request.addr[11:0])-20)/4] & ~write_mask) | (write_data & write_mask);
                if (request.addr[11:0] == 12'h00c) begin
                    if (write_data[1] && write_mask[1]) done_q <= 0;
                    if (write_data[2] && write_mask[2]) begin error_q <= 0; error_code_q <= 0; end
                end
                if (request.addr[11:0] == 12'h008) begin
                    done_q <= 0; error_q <= 0; error_code_q <= 0;
                    for (int i = 0; i < 10; i++) counters[i] <= 0;
                    state_q <= VALIDATE;
                end
            end
            if (reader_failed && !reader_busy && busy && !(state_q inside {VALIDATE,X_START,S_START,W_START,FINISH,FAIL})) begin
                error_code_q <= 3; state_q <= FAIL;
            end else begin
                unique case (state_q)
                    IDLE: ;
                    VALIDATE: begin
                        if (bad_config || overlap) begin error_code_q <= 1; state_q <= FAIL; end
                        else begin max_q <= '0; row_q <= 0; load_q <= 0; state_q <= X_START; end
                    end
                    X_START: state_q <= X_LOAD;
                    X_LOAD: if (stream_valid) begin
                        for (int i = 0; i < 16; i++)
                            if (i*2 < int'(stream_count)) x[load_q+32'(i)] <= $signed(stream_data[i*16 +: 16]);
                        load_q <= load_q+32'(stream_count)/2;
                        if (stream_last) begin load_q <= 0; state_q <= S_START; end
                    end
                    S_START: state_q <= S_LOAD;
                    S_LOAD: if (stream_valid) begin
                        for (int i = 0; i < 4; i++) if (i*8 < int'(stream_count)) begin
                            row_m[load_q+32'(i)] <= stream_data[i*64 +: 32];
                            row_e[load_q+32'(i)] <= $signed(stream_data[i*64+32 +: 32]);
                            if (stream_data[i*64 +: 32] < 32'h40000000 || stream_data[i*64 +: 32] >= 32'h80000000 ||
                                $signed(stream_data[i*64+32 +: 32]) < -256 || $signed(stream_data[i*64+32 +: 32]) > 256)
                                error_code_q <= 2;
                        end
                        load_q <= load_q+32'(stream_count)/8;
                        if (stream_last) state_q <= W_START;
                    end
                    W_START: begin
                        if (error_code_q != 0) state_q <= FAIL;
                        else begin acc_q <= 0; col_q <= 0; state_q <= W_LOAD; end
                    end
                    W_LOAD: if (stream_valid) begin weight_q <= stream_data; weight_bytes_q <= stream_count; state_q <= MAC; end
                    MAC: begin
                        acc_q <= acc_q+mac_sum; col_q <= col_q+32'(take);
                        weight_q <= weight_q >> (8*take); weight_bytes_q <= weight_bytes_q-6'(take);
                        if (col_q+32'(take) == cfg[1]) state_q <= MUL_X_START;
                        else if (int'(weight_bytes_q) == take) state_q <= W_LOAD;
                    end
                    MUL_X_START: state_q <= MUL_X_WAIT;
                    MUL_X_WAIT: if (math_done) begin scaled_x_q <= math_result; state_q <= MUL_W_START; end
                    MUL_W_START: state_q <= MUL_W_WAIT;
                    MUL_W_WAIT: if (math_done) begin
                        work[row_q] <= math_result;
                        if (abs_greater(math_result,max_q)) begin max_q.v <= $signed(magnitude(math_result.v)); max_q.e <= math_result.e; end
                        if (row_q+1 == cfg[0]) state_q <= MAX_SCALE_START;
                        else begin row_q <= row_q+1; state_q <= W_START; end
                    end
                    MAX_SCALE_START: state_q <= MAX_SCALE_WAIT;
                    MAX_SCALE_WAIT: if (math_done) begin
                        if (max_q.v == 0) begin out_m_q <= 32'h40000000; out_e_q <= 1; end
                        else begin
                            out_m_q <= 32'(ceil_multiplier >= (64'd1 << 31) ? (ceil_multiplier+1) >> 1 : ceil_multiplier);
                            out_e_q <= math_result.e+61+(ceil_multiplier >= (64'd1 << 31) ? 1 : 0);
                        end
                        output_row_q <= 0; packed_q <= 0; packed_bytes_q <= 0;
                        write_addr_q <= cfg[5]; scale_write_q <= 0; state_q <= PACK_START;
                    end
                    PACK_START: state_q <= PACK_WAIT;
                    PACK_WAIT: if (math_done) begin
                        if (quant_saturated(math_result,cfg[9] != 0)) counters[8] <= counters[8]+1;
                        if (math_result.v != 0 && quantized_mag == 0) counters[9] <= counters[9]+1;
                        for (int i = 0; i < 4; i++) if (i < width_bytes)
                            packed_q[(int'(packed_bytes_q)+i)*8 +: 8] <= quantized[i*8 +: 8];
                        packed_bytes_q <= packed_bytes_q+6'(width_bytes); output_row_q <= output_row_q+1;
                        state_q <= int'(packed_bytes_q)+width_bytes == 32 || output_row_q+1 == cfg[0] ? WRITE_CMD : PACK_START;
                    end
                    WRITE_CMD: if (wr_cmd_ready) state_q <= WRITE_DATA;
                    WRITE_DATA: if (wr_ready) state_q <= WRITE_RESPONSE;
                    WRITE_RESPONSE: if (wr_rsp_valid) begin
                        if (wr_rsp.error != BUS_OK) begin error_code_q <= 4; state_q <= FAIL; end
                        else if (scale_write_q) state_q <= FINISH;
                        else begin
                            packed_q <= 0; packed_bytes_q <= 0; write_addr_q <= write_addr_q+32;
                            state_q <= output_row_q == cfg[0] ? SCALE_WRITE : PACK_START;
                        end
                    end
                    SCALE_WRITE: begin
                        packed_q <= {192'b0,out_e_q,out_m_q}; packed_bytes_q <= 8;
                        write_addr_q <= cfg[6]; scale_write_q <= 1; state_q <= WRITE_CMD;
                    end
                    FINISH: begin done_q <= 1; state_q <= IDLE; end
                    FAIL: begin error_q <= 1; state_q <= IDLE; end
                    default: state_q <= FAIL;
                endcase
            end
        end
    end
`ifndef SYNTHESIS
    // 合法维度下 |sum| <= 2432*128*32768，远小于 INT64 上限。
    always_ff @(posedge clk) if (!rst && state_q == MAC)
        assert (acc_q+mac_sum <= 64'sd2432*128*32768 && acc_q+mac_sum >= -(64'sd2432*128*32768))
            else $fatal(1,"MM3 accumulator bound violated");
    initial assert (MAC_LANES >= 1 && MAC_LANES <= 32 && 32 % MAC_LANES == 0)
        else $fatal(1,"MM3 MAC_LANES must divide 32");
`endif
endmodule
