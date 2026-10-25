// Module: tb_tcm_address_decode
// Description: Local hit eligibility versus the existing full decoder across boundaries, permissions and high addresses.
module tb_tcm_address_decode;
    timeunit 1ns;
    timeprecision 1ps;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import bus_types_pkg::*;
    import soc_addr_pkg::*;
    bus_req_t request;
    bus_target_e target;
    bus_error_e error;
    logic itcm_ok, dtcm_ok;
    int checks = 0;
    logic [63:0] random_q = 64'h302ce77e86487215;
    logic [63:0] bases [8];
    tcm_address_decode dut (.*);
    address_decode #(.DDR_BYTES(536870912)) reference_decode (.request, .target, .error);
    task automatic check(input logic [63:0] address, input int size, input int permissions);
        request = '{addr:XLEN'(address),size:mem_size_e'(size),write:1'(permissions),
                    execute:1'(permissions >> 1),wdata:'0,wstrb:'0};
        #1ns;
        assert (itcm_ok == (target == TARGET_ITCM && error == BUS_OK) &&
                dtcm_ok == (target == TARGET_DTCM && error == BUS_OK))
            else $fatal(1,"TCM decode mismatch XLEN=%0d address=%h size=%0d permissions=%0d target=%0d error=%0d",
                        XLEN,request.addr,size,permissions,target,error);
        checks++;
    endtask
    initial begin
        bases = '{64'(ITCM_BASE),64'(ITCM_BASE+65536),64'(DTCM_BASE),64'(DTCM_BASE+65536),
                  64'h101000000,64'h101100000,64'h80000000,64'hffffffffffffffff};
        request = '0;
        for (int b = 0; b < 8; b++)
            for (int offset = -8; offset <= 8; offset++)
                for (int size = 0; size < 4; size++)
                    for (int permissions = 0; permissions < 4; permissions++)
                        check(bases[b]+64'(offset),size,permissions);
        for (int n = 0; n < 12000; n++) begin
            random_q ^= random_q << 13;
            random_q ^= random_q >> 7;
            random_q ^= random_q << 17;
            case (n%4)
                0: check(random_q,n%4,(n/4)%4);
                1: check(64'(ITCM_BASE)+64'(random_q[16:0]),(n/4)%4,(n/16)%4);
                2: check(64'(DTCM_BASE)+64'(random_q[16:0]),(n/4)%4,(n/16)%4);
                default: check({random_q[63:32],ITCM_BASE[31:16],random_q[15:0]},(n/4)%4,(n/16)%4);
            endcase
        end
        $display("PASS tb_tcm_address_decode RV%0d checks=%0d seed=302ce77e86487215",XLEN,checks);
        $finish;
    end
endmodule
