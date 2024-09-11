.PHONY: sync sync-*

SHELL:=/bin/bash
export AMI_PREFIX=runs-on-dev

cleanup-dev:
	env $(shell cat .env) AMI_PREFIX=runs-on-dev ./bin/utils/cleanup-amis

cleanup-prod:
	env $(shell cat .env) AMI_PREFIX=runs-on-v2.2 ./bin/utils/cleanup-amis

sync:
	env $(shell cat .env) ./bin/sync

sync-%:
	env $(shell cat .env) ./bin/sync --image-id $*

# Build steps for each distribution and architecture
build-%: sync-%
	env $(shell cat .env) ./bin/build --image-id $*