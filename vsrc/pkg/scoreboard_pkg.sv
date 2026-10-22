// Package: scoreboard_pkg
// Description: Scheduling, recovery and tagged memory contracts for the scoreboard backend.
package scoreboard_pkg;
    import core_config_pkg::*;
    import core_types_pkg::*;
    import pipeline_pkg::*;

    // 调度项只保存待发射包与源值；年龄、结果、异常最终归 ROB 所有。
    typedef struct packed {
        logic mapped;
        retire_id_t id;
    } rename_entry_t;

    typedef struct packed {
        logic valid;
        retire_id_t id;
    } branch_checkpoint_t;

    // 恢复保留分支自身及更老项，丢弃年轻项；full flush 另由架构提交端发起。
    typedef struct packed {
        logic valid;
        retire_id_t id;
        xlen_t pc;
    } branch_recovery_t;

    typedef struct packed {
        retire_id_t id;
        xlen_t address;
        logic write;
        mem_size_e size;
        xlen_t wdata;
        logic [DBUS_BYTES-1:0] wstrb;
    } memory_request_t;

    typedef struct packed {
        retire_id_t id;
        xlen_t data;
        logic error;
    } memory_response_t;

    // LQ/SQ 只共享存活项和寄存描述符视图；状态、结果与写使能由各队列独立持有。
    typedef struct packed {
        logic valid;
        logic killed;
        lsu_descriptor_t descriptor;
    } lsu_entry_view_t;

    // 仅无副作用的物理内存允许提前读，MMIO 和高位地址须取得 ROB 队头授权。
    function automatic logic speculative_ram(input xlen_t address);
        return address < xlen_t'(soc_addr_pkg::MTIME_BASE) ||
               ((address >> 31) == xlen_t'(1));
    endfunction

    typedef enum logic [2:0] {
        SCHED_ALU, SCHED_BRANCH, SCHED_MDU, SCHED_MEMORY, SCHED_SERIAL
    } schedule_class_e;

    function automatic schedule_class_e schedule_class(input d2_ex_t packet);
        if (packet.exc.valid || packet.uop.csr_valid || packet.uop.sys_op != SYS_NONE)
            return SCHED_SERIAL;
        else if (packet.uop.branch_op != BR_NONE)
            return SCHED_BRANCH;
        else if (packet.uop.fu == FU_MULDIV)
            return SCHED_MDU;
        else if (packet.uop.mem_read || packet.uop.mem_write)
            return SCHED_MEMORY;
        else
            return SCHED_ALU;
    endfunction

    // 前五口来自已完成结果和 ALU/MDU 入 CMP，随后分开合法读返回和 Store 转发提示。
    // 分支屏蔽提示时，捕获与当拍视图同时屏蔽；寄存模式仍允许 ALU/MDU 保存提示数据。
    localparam int unsigned LSU_RETURN_FIRST = 5;
    localparam int unsigned LSU_HINT_FIRST = 7;
    function automatic logic operand_forward_enabled(
        input d2_ex_t packet, input int unsigned portno, input logic issue_view
    );
        if (portno < LSU_RETURN_FIRST) return 1;
        unique case (SCHEDULER_FORWARD_MODE)
            IQ_FORWARD_ALL: return 1;
            IQ_FORWARD_BRANCH_COMPLETION: return schedule_class(packet) != SCHED_BRANCH;
            IQ_FORWARD_LSU_CAPTURE: return !issue_view && schedule_class(packet) != SCHED_BRANCH;
            IQ_FORWARD_STORE_CAPTURE: return portno < LSU_HINT_FIRST ||
                (!issue_view && schedule_class(packet) != SCHED_BRANCH);
            default: return 0;
        endcase
    endfunction

    // 资源契约不做寄存器名比较；真实 RAW 由绑定标签的 scoreboard 决定。
    // 单分支/MDU 资源共享，CSR/系统指令独占；两条访存允许进入两个 AGU。
    function automatic logic resources_pair(
        input schedule_class_e first_class, second_class
    );
        return first_class != SCHED_SERIAL && second_class != SCHED_SERIAL &&
            !(first_class == SCHED_BRANCH && second_class == SCHED_BRANCH) &&
            !(first_class == SCHED_MDU && second_class == SCHED_MDU);
    endfunction

    // 同一存活 ROB 窗口中，槽号小于 head 的项已经回卷，比未回卷项年轻。
    // 同一侧直接比较槽号，避免先做两次环形减法；代次只校验身份，不参与排序。
    function automatic logic younger_than(
        input retire_id_t candidate, boundary,
        input logic [RETIRE_IDX_W-1:0] head_slot
    );
        logic candidate_wrapped, boundary_wrapped;
        candidate_wrapped = candidate.slot < head_slot;
        boundary_wrapped = boundary.slot < head_slot;
        return candidate_wrapped != boundary_wrapped ? candidate_wrapped :
               candidate.slot > boundary.slot;
    endfunction
endpackage
