IMAGE_IDS := $(shell yq e '.images[].id' config.yml)
.PHONY: $(addprefix sync-,$(IMAGE_IDS)) $(addprefix build-,$(IMAGE_IDS))

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

define debug_template
debug-$(1): sync-$(1)
	env $$(shell cat .env) bundle exec bin/build --image-id $(1) --debug
endef

$(foreach id,$(IMAGE_IDS),$(eval $(call sync_template,$(id))))
$(foreach id,$(IMAGE_IDS),$(eval $(call build_template,$(id))))
$(foreach id,$(IMAGE_IDS),$(eval $(call debug_template,$(id))))

reset:
	git reset releases && git checkout releases

cleanup-dev:
	env $(shell cat .env) AMI_PREFIX=runs-on-dev bundle exec bin/utils/cleanup-amis

cleanup-prod:
	env $(shell cat .env) AMI_PREFIX=runs-on-v2.2 bundle exec bin/utils/cleanup-amis

setup-roles:
	aws iam create-role --role-name SSMInstanceProfile --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
	aws iam attach-role-policy --role-name SSMInstanceProfile --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
	aws iam create-instance-profile --instance-profile-name SSMInstanceProfile
	aws iam add-role-to-instance-profile --instance-profile-name SSMInstanceProfile --role-name SSMInstanceProfile

efs-utils: dist/efs-utils/amazon-efs-utils-*_amd64.deb dist/efs-utils/amazon-efs-utils-*_arm64.deb
	AWS_PROFILE=runs-on-releaser aws s3 sync dist/efs-utils s3://runs-on/tools/efs-utils

dist/efs-utils/amazon-efs-utils-*_amd64.deb:	
	rm -f dist/efs-utils/*_amd64.deb
	mkdir -p dist/efs-utils
	./scripts/efs-utils.sh ubuntu:22.04 amd64;

dist/efs-utils/amazon-efs-utils-*_arm64.deb:
	rm -f dist/efs-utils/*_arm64.deb
	mkdir -p dist/efs-utils
	./scripts/efs-utils.sh ubuntu:22.04 arm64;
