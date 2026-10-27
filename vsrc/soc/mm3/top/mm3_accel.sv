// Module: mm3_accel
// Description: Backward-compatible GEMV MMIO plus versioned integer operator descriptor engine.
module mm3_accel #(
    parameter int unsigned DDR_BYTES = 128*1024*1024,
    parameter int unsigned MAC_LANES = mm3_config_pkg::MM3_GEMV_LANES
) (
    input logic clk, rst,
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
    import bus_types_pkg::*;import block_types_pkg::*;
    logic select_ext,owner_valid,owner_ext,accept_slot;
    logic l_req_ready,l_rsp_valid,l_rsp_ready,l_req_valid,legacy_busy;
    bus_rsp_t l_response,e_response;
    logic e_req_ready,e_rsp_valid,e_rsp_ready,e_req_valid;
    logic[31:0] read_data,write_data,write_mask,opcode,descriptor,error_code,engine_error;
    logic access_error,access_fire,running,complete,error,last_ext,launch,engine_done,engine_failed,busy;
    logic[63:0] cycles,engine_sat,engine_under,last_sat,last_under;
    logic[1:0] crdv,crdr,crv,crr,cwdv,cwdr,cwv,cwr,cbv,cbr;
    block_cmd_t crcmd[2],cwcmd[2];block_r_t crdata[2];block_w_t cwdata[2];block_b_t cbdata[2];
    assign busy=running||legacy_busy;
    always_comb begin
        select_ext=request.addr[11:0]>=12'h090;
        if((last_ext||opcode!=0)&&(request.addr[11:0]==8||request.addr[11:0]==12||request.addr[11:0]==16||
            (request.addr[11:0]>=12'h040&&request.addr[11:0]<12'h090)))select_ext=1;
        if(running&&request.write)select_ext=1;
        rsp_valid=owner_valid&&(owner_ext?e_rsp_valid:l_rsp_valid);response=owner_ext?e_response:l_response;
        accept_slot=!owner_valid||(rsp_valid&&rsp_ready);
        req_ready=accept_slot&&(select_ext?e_req_ready:l_req_ready);
        e_req_valid=req_valid&&accept_slot&&select_ext;l_req_valid=req_valid&&accept_slot&&!select_ext;
        e_rsp_ready=rsp_ready&&owner_valid&&owner_ext;l_rsp_ready=rsp_ready&&owner_valid&&!owner_ext;
        read_data=0;access_error=0;
        case(request.addr[11:0])
            12'h008:access_error=!request.write||busy||(write_data&write_mask)!=1||opcode==0;
            12'h00c:begin read_data={29'b0,error,complete,running};access_error=request.write&&(busy|||(write_data&write_mask&~32'd6));end
            12'h010:begin read_data=error_code;access_error=request.write;end
            12'h040:begin read_data=32'(cycles);access_error=request.write;end
            12'h044:begin read_data=32'(cycles>>32);access_error=request.write;end
            12'h080:begin read_data=32'(last_sat);access_error=request.write;end
            12'h084:begin read_data=32'(last_sat>>32);access_error=request.write;end
            12'h088:begin read_data=32'(last_under);access_error=request.write;end
            12'h08c:begin read_data=32'(last_under>>32);access_error=request.write;end
            12'h090:begin read_data=opcode;access_error=request.write&&(busy||(write_data&write_mask)>9);end
            12'h094:begin read_data=descriptor;access_error=request.write&&busy;end
            12'h098:begin read_data=32'h00010000;access_error=request.write;end
            12'h09c:begin read_data=32'h000003fe;access_error=request.write;end
            default:access_error=1;
        endcase
        rd_cmd_valid=crdv[running];rd_cmd=crcmd[running];rd_ready=crr[running];
        wr_cmd_valid=cwdv[running];wr_cmd=cwcmd[running];wr_valid=cwv[running];wr_data=cwdata[running];wr_rsp_ready=cbr[running];
        for(int i=0;i<2;i++)begin crdr[i]=rd_cmd_ready&&(running==1'(i));crv[i]=rd_valid&&(running==1'(i));crdata[i]=rd_data;
            cwdr[i]=wr_cmd_ready&&(running==1'(i));cwr[i]=wr_ready&&(running==1'(i));cbv[i]=wr_rsp_valid&&(running==1'(i));cbdata[i]=wr_rsp;end
    end
    mmio_endpoint u_ext_mmio(.clk,.rst,.req_valid(e_req_valid),.req_ready(e_req_ready),.request,.rsp_valid(e_rsp_valid),.rsp_ready(e_rsp_ready),.response(e_response),.read_data,.access_error,.access_fire,.write_data,.write_mask);
    mm3_gemv_accel #(.DDR_BYTES(DDR_BYTES),.MAC_LANES(MAC_LANES)) u_gemv(
        .clk,.rst,.busy_out(legacy_busy),.req_valid(l_req_valid),.req_ready(l_req_ready),.request,.rsp_valid(l_rsp_valid),.rsp_ready(l_rsp_ready),.response(l_response),
        .rd_cmd_valid(crdv[0]),.rd_cmd_ready(crdr[0]),.rd_cmd(crcmd[0]),.rd_valid(crv[0]),.rd_ready(crr[0]),.rd_data(crdata[0]),
        .wr_cmd_valid(cwdv[0]),.wr_cmd_ready(cwdr[0]),.wr_cmd(cwcmd[0]),.wr_valid(cwv[0]),.wr_ready(cwr[0]),.wr_data(cwdata[0]),.wr_rsp_valid(cbv[0]),.wr_rsp_ready(cbr[0]),.wr_rsp(cbdata[0]));
    mm3_ops_engine #(.DDR_BYTES(DDR_BYTES)) u_ops(.clk,.rst,.start(launch),.descriptor_address(descriptor),.expected_op(opcode),.busy(),.done(engine_done),.failed(engine_failed),.error_code(engine_error),.saturated(engine_sat),.underflow(engine_under),
        .rd_cmd_valid(crdv[1]),.rd_cmd_ready(crdr[1]),.rd_cmd(crcmd[1]),.rd_valid(crv[1]),.rd_ready(crr[1]),.rd_data(crdata[1]),
        .wr_cmd_valid(cwdv[1]),.wr_cmd_ready(cwdr[1]),.wr_cmd(cwcmd[1]),.wr_valid(cwv[1]),.wr_ready(cwr[1]),.wr_data(cwdata[1]),.wr_rsp_valid(cbv[1]),.wr_rsp_ready(cbr[1]),.wr_rsp(cbdata[1]));
    always_ff @(posedge clk)begin
        if(rst)begin owner_valid<=0;owner_ext<=0;opcode<=0;descriptor<=0;error_code<=0;running<=0;complete<=0;error<=0;last_ext<=0;launch<=0;cycles<=0;last_sat<=0;last_under<=0;end
        else begin
            launch<=0;
            if(req_valid&&req_ready)begin owner_valid<=1;owner_ext<=select_ext;end
            else if(rsp_valid&&rsp_ready)owner_valid<=0;
            if(running)cycles<=cycles+1;
            if(engine_done&&running)begin
                running<=0;complete<=!engine_failed;error<=engine_failed;error_code<=engine_error;
                last_sat<=(opcode==5||opcode==7||opcode==8||engine_failed)?0:engine_sat;
                last_under<=(opcode==5||opcode==7||opcode==8||engine_failed)?0:engine_under;
            end
            if(access_fire&&request.write)case(request.addr[11:0])
                12'h090:opcode<=(opcode&~write_mask)|(write_data&write_mask);
                12'h094:descriptor<=(descriptor&~write_mask)|(write_data&write_mask);
                12'h008:begin running<=1;last_ext<=1;launch<=1;complete<=0;error<=0;error_code<=0;cycles<=0;last_sat<=0;last_under<=0;end
                12'h00c:begin
                    if(write_data[1]&&write_mask[1])complete<=0;
                    if(write_data[2]&&write_mask[2])begin error<=0;error_code<=0;end
                    opcode<=0;last_ext<=0;
                end
                default:;
            endcase
        end
    end
endmodule
