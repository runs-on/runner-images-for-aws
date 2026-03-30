IMAGE_IDS := $(shell yq e '.images[].id' config.yml)
.DEFAULT_GOAL := help
.PHONY: help $(addprefix sync-,$(IMAGE_IDS)) $(addprefix build-,$(IMAGE_IDS)) $(addprefix debug-,$(IMAGE_IDS)) inspector-report inspector-stack-deploy inspector-stack-run inspector-stack-watch

SHELL:=/bin/bash
export AMI_PREFIX=runs-on-dev

AWS_REGION ?= us-east-1
INSPECTOR_STACK_NAME ?= runs-on-inspector-ami-scanner
INSPECTOR_NOTIFICATION_EMAIL ?= security@runs-on.com
INSPECTOR_SCHEDULE_EXPRESSION ?= cron(0 2 * * ? *)
INSPECTOR_REPORT_FORMAT ?= JSON
INSPECTOR_AMI_SCAN_TAG_NAME ?= inspector_scan
INSPECTOR_AMI_SCAN_TAG_VALUE ?= true
INSPECTOR_PROD_PREFIX ?= runs-on-v2.2
INSPECTOR_DEV_PREFIX ?= runs-on-dev
INSPECTOR_SCANNER_CONFIG_JSON := $(shell ruby bin/inspector-scanner-config)

help:
	@printf "Available commands:\n"
	@printf "  sync-<image-id>             Sync one image template\n"
	@printf "  build-<image-id>            Sync and build one image\n"
	@printf "  debug-<image-id>            Sync and build one image in debug mode\n"
	@printf "  cleanup-dev                 Clean up development AMIs\n"
	@printf "  cleanup-prod                Clean up production AMIs\n"
	@printf "  inspector-stack-deploy      Deploy the Inspector AMI scanner stack\n"
	@printf "  inspector-report            Show CVE findings for an Inspector report\n"
	@printf "  inspector-stack-run         Start a manual Inspector scanner execution\n"
	@printf "  inspector-stack-watch       List recent Inspector scanner executions\n"
	@printf "  setup-roles                 Create the legacy SSM instance profile\n"
	@printf "  efs-utils                   Build and upload efs-utils packages\n"
	@printf "  reset                       Reset generated releases changes\n"
	@printf "\nImage IDs:\n"
	@printf "  %s\n" $(IMAGE_IDS)

define sync_template
sync-$(1):
	env $$(shell cat .env) mise exec -- bundle exec bin/sync --image-id $(1)
endef

define build_template
build-$(1): sync-$(1)
	env $$(shell cat .env) mise exec -- bundle exec bin/build --image-id $(1)
endef

define debug_template
debug-$(1): sync-$(1)
	env $$(shell cat .env) mise exec -- bundle exec bin/build --image-id $(1) --debug
endef

$(foreach id,$(IMAGE_IDS),$(eval $(call sync_template,$(id))))
$(foreach id,$(IMAGE_IDS),$(eval $(call build_template,$(id))))
$(foreach id,$(IMAGE_IDS),$(eval $(call debug_template,$(id))))

reset:
	git reset releases && git checkout releases

cleanup-dev:
	env $(shell cat .env) AMI_PREFIX=runs-on-dev mise exec -- bundle exec bin/utils/cleanup-amis

cleanup-prod:
	env $(shell cat .env) AMI_PREFIX=runs-on-v2.2 mise exec -- bundle exec bin/utils/cleanup-amis

setup-roles:
	aws iam create-role --role-name SSMInstanceProfile --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
	aws iam attach-role-policy --role-name SSMInstanceProfile --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
	aws iam create-instance-profile --instance-profile-name SSMInstanceProfile
	aws iam add-role-to-instance-profile --instance-profile-name SSMInstanceProfile --role-name SSMInstanceProfile

inspector-stack-deploy:
	aws cloudformation deploy \
	  --region $(AWS_REGION) \
	  --stack-name $(INSPECTOR_STACK_NAME) \
	  --template-file cloudformation/inspector-ami-scanner.yml \
	  --capabilities CAPABILITY_NAMED_IAM \
	  --parameter-overrides \
	    NotificationEmail='$(INSPECTOR_NOTIFICATION_EMAIL)' \
	    ScannerScheduleExpression='$(INSPECTOR_SCHEDULE_EXPRESSION)' \
	    InspectorReportFormat='$(INSPECTOR_REPORT_FORMAT)' \
	    AmiScanTagName='$(INSPECTOR_AMI_SCAN_TAG_NAME)' \
	    AmiScanTagValue='$(INSPECTOR_AMI_SCAN_TAG_VALUE)' \
	    ProdPrefix='$(INSPECTOR_PROD_PREFIX)' \
	    DevPrefix='$(INSPECTOR_DEV_PREFIX)' \
	    ScannerConfigJson='$(INSPECTOR_SCANNER_CONFIG_JSON)'

inspector-report:
	@if [ -z "$(S3_URI)" ]; then \
	  echo "Usage: AWS_PROFILE=... make inspector-report S3_URI=s3://bucket/report-prefix-or-file.json" >&2; \
	  exit 1; \
	fi
	@./scripts/inspector-report-findings.sh "$(S3_URI)"

inspector-stack-run:
	@state_machine_arn="$$(aws cloudformation describe-stacks --region $(AWS_REGION) --stack-name $(INSPECTOR_STACK_NAME) --query 'Stacks[0].Outputs[?OutputKey==`ScannerStateMachineArn`].OutputValue' --output text)"; \
	aws stepfunctions start-execution \
	  --region $(AWS_REGION) \
	  --state-machine-arn "$$state_machine_arn"

inspector-stack-watch:
	@state_machine_arn="$$(aws cloudformation describe-stacks --region $(AWS_REGION) --stack-name $(INSPECTOR_STACK_NAME) --query 'Stacks[0].Outputs[?OutputKey==`ScannerStateMachineArn`].OutputValue' --output text)"; \
	aws stepfunctions list-executions \
	  --region $(AWS_REGION) \
	  --state-machine-arn "$$state_machine_arn" \
	  --max-results 10 \
	  --query 'executions[].{Name:name,Status:status,Started:startDate,Stopped:stopDate}' \
	  --output table

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
