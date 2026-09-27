# Shared platform selection for benchmark build/run scripts (source after config).
bench_top=tb_benchmark
bench_tb=tb/benchmark/tb_benchmark.sv
bench_files=scripts/sim_files.f
if [[ "${SOC:-0}" == "1" ]]; then
    config="${config}-soc"
    bench_top=tb_soc_benchmark
    bench_tb=tb/soc/tb_soc_benchmark.sv
    bench_files=scripts/soc_files.f
fi
