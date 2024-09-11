.PHONY: sync sync-*

SHELL:=/bin/bash
export AMI_PREFIX=runs-on-dev

cleanup-dev:
	env $(shell cat .env) AMI_PREFIX=runs-on-dev bundle exec bin/utils/cleanup-amis

cleanup-prod:
	env $(shell cat .env) AMI_PREFIX=runs-on-v2.2 bundle exec bin/utils/cleanup-amis

sync:
	env $(shell cat .env) bundle exec bin/sync

sync-%:
	env $(shell cat .env) bundle exec bin/sync --image-id $*

# Build steps for each distribution and architecture
build-%: sync-%
	env $(shell cat .env) bundle exec bin/build --image-id $*