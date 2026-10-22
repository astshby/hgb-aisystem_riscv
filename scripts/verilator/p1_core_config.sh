# P1 Core profile; source from the repository root before invoking make or runners.
# M0/M1 的平台参数由调用入口设置；该文件只固定经同镜像比较选择的 Core 参数。
export CORE_BACKEND=scoreboard ISSUE_WIDTH=2 RETIRE_ENTRIES=32
export SPLIT_ISSUE_QUEUE=1 INTEGER_QUEUE_ENTRIES=8 MEMORY_QUEUE_ENTRIES=4
export LIMITED_INTEGER_OOO=1 SCHEDULER_FORWARD_MODE=3
export PREDICTOR_MODE=1 RAS_ENABLE=1 MUL_IMPL=0 DIV_IMPL=1
