SHELL := /bin/bash
FORGE ?= forge
PYTHON ?= .venv/bin/python

.PHONY: install build test test-contracts test-py coverage deploy deploy-local ping up demo ui

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

# Base Sepolia. Only the admin address needs faucet ETH.
deploy:
	set -a && source .env && set +a && cd contracts && $(FORGE) script script/Deploy.s.sol --rpc-url "$$RPC_URL" --broadcast --slow
	set -a && source .env && set +a && $(PYTHON) scripts/export_deployment.py "$$CHAIN_ID" base-sepolia

# Local rehearsal on anvil (uses anvil's funded default key as admin)
deploy-local:
	set -a && source .env && set +a && cd contracts && ADMIN_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 $(FORGE) script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
	$(PYTHON) scripts/export_deployment.py 31337 anvil

ping:
	$(PYTHON) -m services.ledger.client ping

up:
	@echo "TODO (Phases 4-7): start workspaces, coordinator and bank sandbox"

demo:
	@echo "TODO (Phase 9): $(PYTHON) scripts/run_demo_scenario.py"

ui:
	@echo "TODO (Phase 8): $(PYTHON) -m streamlit run ui/app.py"
