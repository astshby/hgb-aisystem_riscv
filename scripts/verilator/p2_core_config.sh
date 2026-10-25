# Shared P2 system build profile; source from the repository root.
# 未选择配置时保留原 P2/P0 对照；先 source p1_core_config.sh 即使用完整 P1 参数。
export CORE_BACKEND="${CORE_BACKEND:-scoreboard}"
export ISSUE_WIDTH="${ISSUE_WIDTH:-${CORE_ISSUE_WIDTH:-2}}"
export RETIRE_ENTRIES="${RETIRE_ENTRIES:-${CORE_RETIRE_ENTRIES:-16}}"
export MUL_IMPL="${MUL_IMPL:-0}" DIV_IMPL="${DIV_IMPL:-1}"
source scripts/verilator/core_build_config.sh
[[ "$core_backend" == scoreboard && "$core_issue_width" == 2 &&
   "$MUL_IMPL" =~ ^[012]$ && "$DIV_IMPL" =~ ^[01]$ ]] || {
    echo 'P2 requires a dual-issue scoreboard profile and valid MDU backends' >&2
    return 2
}
p2_core_flags=("-DCORE_MUL_IMPL=$MUL_IMPL" "-DCORE_DIV_IMPL=$DIV_IMPL" "${core_microarch_flags[@]}")
p2_core_build_tag="m${MUL_IMPL}d${DIV_IMPL}-${core_build_tag}"
