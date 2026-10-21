// Module: bind_scoreboard_metrics
// Description: Connects passive benchmark counters without adding any synthesized Core ports or state.
`default_nettype none
bind scoreboard_core scoreboard_metrics u_benchmark_metrics (
    .clk, .rst, .issue_fire, .retire_fire,
    .redirect(selected_redirect.valid), .iq_empty(iq_occupancy == 0 && !issue_busy),
    .head_operands_ready(issue_busy || iq_ready[0]), .head_unit_ready(!issue_busy || lane_ready[0]), .head_class(lane_class[0]),
    .dispatch_pending(decode_q[0].valid),
    .rob_full(rob_occupancy == core_config_pkg::RETIRE_ENTRIES),
    .iq_full(iq_capacity == 0), .checkpoint_blocked(!checkpoint_ready),
    .memory_request_fire(mem_req_valid & mem_req_ready),
    .memory_response_fire(mem_rsp_valid & mem_rsp_ready),
    .forward_fire(u_lsu.forward_fire), .completion_sources($countones(source_valid))
);
`default_nettype wire
