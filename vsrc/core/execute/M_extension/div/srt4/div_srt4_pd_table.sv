// Module: div_srt4_pd_table
// Description: Provides radix-4 SRT selection constants from four normalized divisor bits.
// PD表格，用于qds选择
module div_srt4_pd_table (
    input  logic [3:0] divisor_prefix,
    output logic [5:0] select_one,
    output logic [5:0] select_two
);
    // 部分余数以 1/16 为单位；两个边界位于约 D/2 和 3D/2 的重叠选择区。
    // 显式表项保留 PD 表边界，后续改变截断位数时需重新生成并验证。
    always_comb begin
        unique case (divisor_prefix)
            4'h8: begin select_one = 6'd8;  select_two = 6'd24; end
            4'h9: begin select_one = 6'd9;  select_two = 6'd27; end
            4'ha: begin select_one = 6'd10; select_two = 6'd30; end
            4'hb: begin select_one = 6'd11; select_two = 6'd33; end
            4'hc: begin select_one = 6'd12; select_two = 6'd36; end
            4'hd: begin select_one = 6'd13; select_two = 6'd39; end
            4'he: begin select_one = 6'd14; select_two = 6'd42; end
            4'hf: begin select_one = 6'd15; select_two = 6'd45; end
            default: begin select_one = 6'd8; select_two = 6'd24; end
        endcase
    end
endmodule
