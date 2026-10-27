.PHONY: rt-thread-fetch rt-thread
rt-thread-fetch:
	bash scripts/rt-thread/fetch.sh

rt-thread:
	bash scripts/rt-thread/run.sh $(XLEN)

