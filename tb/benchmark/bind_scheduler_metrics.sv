// Module: bind_scheduler_metrics
// Description: Observes an instantiated integer IQ without adding synthesized ports, state or backpressure.
`default_nettype none
bind integer_issue_queue scoreboard_scheduler_metrics #(.DEPTH(DEPTH)) u_scheduler_metrics (
    .clk, .rst, .flush, .recovery, .head_slot, .mdu_available,
    .valid_slots(valid_q), .eligible, .packets(operand_view), .selected(issue_packet),
    .producers, .accept_count(pop_count)
);
`default_nettype wire
