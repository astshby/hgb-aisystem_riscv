// Module: div_srt4_normalize
// Description: Normalizes an unsigned divisor and applies the same shift to the dividend.
// LZC(前导0去除)，归一化与对齐，PD表必须
module div_srt4_normalize #(
    parameter int WIDTH = core_config_pkg::XLEN
) (
    input  logic [WIDTH-1:0]   dividend,
    input  logic [WIDTH-1:0]   divisor,
    output logic [$clog2(WIDTH)-1:0] shift,
    output logic [2*WIDTH-1:0] normalized_dividend,
    output logic [WIDTH-1:0]   normalized_divisor
);
    localparam int SHIFT_W = $clog2(WIDTH);
    logic leading_one_found;

    // 除数最高的 1 移到 WIDTH-1，被除数同比例移位，商保持不变。
    always_comb begin
        shift = '0;
        leading_one_found = 1'b0;
        for (int bit_index = WIDTH-1; bit_index >= 0; bit_index--) begin
            if (!leading_one_found && divisor[bit_index]) begin
                shift = SHIFT_W'(WIDTH - 1 - bit_index);
                leading_one_found = 1'b1;
            end
        end
        normalized_dividend = (2*WIDTH)'(dividend) << shift;
        normalized_divisor = divisor << shift;
    end
endmodule
