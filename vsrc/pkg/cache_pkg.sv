// Package: cache_pkg
// Description: Cache maintenance command and completion types; no behavioral functions.
package cache_pkg;
    typedef enum logic [1:0] {
        CACHE_NONE = 2'd0, CACHE_INVALIDATE = 2'd1,
        CACHE_CLEAN = 2'd2, CACHE_FLUSH = 2'd3
    } cache_maint_op_e;
    typedef enum logic [1:0] {
        CACHE_OK = 2'd0, CACHE_WRITEBACK_ERROR = 2'd1, CACHE_DIRTY_ERROR = 2'd2
    } cache_maint_error_e;
endpackage
