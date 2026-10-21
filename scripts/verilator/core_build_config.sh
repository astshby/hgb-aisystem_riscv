# Shared core microarchitecture selection; source from the repository root.
# 每个 RTL 构建入口使用同一组宏和目录标签，避免切换预测器后误跑旧模型。
core_predictor_mode="${PREDICTOR_MODE:-${CORE_PREDICTOR_MODE:-0}}"
core_ras_enable="${RAS_ENABLE:-${CORE_RAS_ENABLE:-0}}"
core_retire_entries="${RETIRE_ENTRIES:-${CORE_RETIRE_ENTRIES:-4}}"
core_issue_width="${ISSUE_WIDTH:-${CORE_ISSUE_WIDTH:-1}}"
core_backend="${CORE_BACKEND:-legacy}"
if [[ ! "$core_predictor_mode" =~ ^[01]$ || ! "$core_ras_enable" =~ ^[01]$ ||
      ! "$core_retire_entries" =~ ^(2|4|8|16|32)$ || ! "$core_issue_width" =~ ^[12]$ ]]; then
    echo "invalid core configuration: predictor=$core_predictor_mode ras=$core_ras_enable retire=$core_retire_entries issue=$core_issue_width" >&2
    return 2
fi
core_microarch_flags=("-DCORE_PREDICTOR_MODE=$core_predictor_mode"
    "-DCORE_RAS_ENABLE=$core_ras_enable" "-DCORE_RETIRE_ENTRIES=$core_retire_entries"
    "-DCORE_ISSUE_WIDTH=$core_issue_width")
core_build_tag="p${core_predictor_mode}r${core_ras_enable}q${core_retire_entries}i${core_issue_width}"
case "$core_backend" in
    legacy) ;;
    scoreboard)
        [[ "$core_issue_width" == 2 ]] || {
            echo 'scoreboard checkpoint requires ISSUE_WIDTH=2' >&2
            return 2
        }
        core_microarch_flags+=("-DCORE_SCOREBOARD")
        core_build_tag="${core_build_tag}-scoreboard"
        core_split_issue_queue="${SPLIT_ISSUE_QUEUE:-0}"
        core_integer_queue_entries="${INTEGER_QUEUE_ENTRIES:-8}"
        core_memory_queue_entries="${MEMORY_QUEUE_ENTRIES:-4}"
        [[ "$core_split_issue_queue" =~ ^[01]$ && "$core_integer_queue_entries" =~ ^(2|4|8|16)$ &&
           "$core_memory_queue_entries" =~ ^(2|4|8)$ ]] || {
            echo 'invalid split IQ configuration' >&2; return 2;
        }
        core_microarch_flags+=("-DCORE_SPLIT_ISSUE_QUEUE=$core_split_issue_queue"
            "-DCORE_ISSUE_QUEUE_ENTRIES=$core_integer_queue_entries"
            "-DCORE_MEMORY_QUEUE_ENTRIES=$core_memory_queue_entries")
        if [[ "$core_split_issue_queue" != 0 || "$core_integer_queue_entries" != 8 || "$core_memory_queue_entries" != 4 ]]; then
            core_build_tag+="-s${core_split_issue_queue}j${core_integer_queue_entries}m${core_memory_queue_entries}"
        fi
        ;;
    *) echo "invalid CORE_BACKEND=$core_backend" >&2; return 2 ;;
esac
