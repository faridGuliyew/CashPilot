SHELL := /bin/bash
FORGE ?= forge
PYTHON ?= .venv/bin/python

.PHONY: install build test test-contracts test-py coverage deploy up demo ui

install:
	python3 -m venv .venv
	.venv/bin/pip install -e .

build:
	cd contracts && $(FORGE) build

test: test-contracts test-py

test-contracts:
	cd contracts && $(FORGE) test -vv

test-py:
	$(PYTHON) -m pytest -q

coverage:
	cd contracts && $(FORGE) coverage --no-match-coverage "(test|script)/" | grep -E "^\|" > ../evidence/forge-coverage.txt
	cat evidence/forge-coverage.txt

deploy:
	@echo "TODO (Phase 3): deploy InvoiceRegistry + AgreementLedger"

up:
	@echo "TODO (Phases 4-7): start workspaces, coordinator and bank sandbox"

demo:
	@echo "TODO (Phase 9): $(PYTHON) scripts/run_demo_scenario.py"

ui:
	@echo "TODO (Phase 8): $(PYTHON) -m streamlit run ui/app.py"
