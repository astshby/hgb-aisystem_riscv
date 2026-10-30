# Applications and locked assets are source-controlled; build/ is disposable.
SOFTWARE_APP ?= all
.PHONY: software-list software-doctor software-prepare software-build software-test
software-list software-doctor software-prepare software-build software-test:
	python3 scripts/software.py $(patsubst software-%,%,$@) --app $(SOFTWARE_APP) --xlen $(XLEN)
