# P1 Core profile; source from the repository root before invoking make or runners.
# M0/M1 的平台参数由调用入口设置；该文件只固定经同镜像比较选择的 Core 参数。
export CORE_BACKEND=scoreboard ISSUE_WIDTH=2 RETIRE_ENTRIES=32
export SPLIT_ISSUE_QUEUE=1 INTEGER_QUEUE_ENTRIES=8 MEMORY_QUEUE_ENTRIES=4
# 深水区同镜像对照：关闭有限整数乱序后 H0 81.7327 MHz、M0 3.150157；
# 保留乱序时 H0 57.1919 MHz、M0 3.219653，频率不足以抵消 CoreMark/MHz。
export LIMITED_INTEGER_OOO=0 SCHEDULER_FORWARD_MODE=3
# 正式配置移除 RAS；GShare/Local/chooser 保留，RAS 历史候选由独立分支复现。
export PREDICTOR_MODE=1 RAS_ENABLE=0 MUL_IMPL=0 DIV_IMPL=1
