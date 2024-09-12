IMAGE_IDS := $(shell yq e '.images[].id' config.yml)
.PHONY: sync $(addprefix sync-,$(IMAGE_IDS)) $(addprefix build-,$(IMAGE_IDS))

SHELL:=/bin/bash
export AMI_PREFIX=runs-on-dev

define sync_template
sync-$(1):
	env $$(shell cat .env) bundle exec bin/sync --image-id $(1)
endef

define build_template
build-$(1): sync-$(1)
	env $$(shell cat .env) bundle exec bin/build --image-id $(1)
endef

$(foreach id,$(IMAGE_IDS),$(eval $(call sync_template,$(id))))
$(foreach id,$(IMAGE_IDS),$(eval $(call build_template,$(id))))

cleanup-dev:
	env $(shell cat .env) AMI_PREFIX=runs-on-dev bundle exec bin/utils/cleanup-amis

cleanup-prod:
	env $(shell cat .env) AMI_PREFIX=runs-on-v2.2 bundle exec bin/utils/cleanup-amis