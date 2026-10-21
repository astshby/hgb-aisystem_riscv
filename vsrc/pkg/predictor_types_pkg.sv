// Package: predictor_types_pkg
// Description: Standalone return-stack events, independent of pipeline ownership.
package predictor_types_pkg;
    typedef enum logic [1:0] {
        RAS_NONE, RAS_POP, RAS_PUSH, RAS_POP_PUSH
    } ras_op_e;

    typedef struct packed {
        ras_op_e op;
        core_types_pkg::xlen_t addr;
    } ras_event_t;
endpackage
