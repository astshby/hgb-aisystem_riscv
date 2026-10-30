.PHONY: rt-thread-fetch rt-thread
rt-thread-fetch:
	bash scripts/rt-thread/fetch.sh

rt-thread:
	bash scripts/rt-thread/run.sh $(XLEN)

.PHONY: rt-thread-demo rt-thread-demo-test
rt-thread-demo:
	RTTHREAD_APP=demo bash scripts/rt-thread/build.sh $(XLEN)
rt-thread-demo-test:
	python3 -m unittest tb.scripts.test_rt_demo

