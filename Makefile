SHELL := /bin/bash
FORGE ?= forge
PYTHON ?= .venv/bin/python

.PHONY: install test test-contracts test-agent coverage build deploy demo ui

install:
	python3 -m venv .venv
	.venv/bin/pip install -e agent

build:
	cd contracts && $(FORGE) build

test: test-contracts test-agent

test-contracts:
	cd contracts && $(FORGE) test -vv

coverage:
	cd contracts && $(FORGE) coverage --no-match-coverage "(test|script)/" --ir-minimum | grep -E "^\|" > ../evidence/forge-coverage.txt
	cat evidence/forge-coverage.txt

test-agent:
	cd agent && ../$(PYTHON) -m pytest -q

deploy:
	@echo "TODO (Phase 2): forge script script/Deploy.s.sol --broadcast"

demo:
	@echo "TODO (Phase 6): $(PYTHON) scripts/run_demo_scenario.py"

ui:
	@echo "TODO (Phase 5): $(PYTHON) -m streamlit run ui/app.py"
