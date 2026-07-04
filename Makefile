.PHONY: index validate validate-aws generate-templates generate-all local-smoke local-smoke-all

index:
	@./scripts/build-index.sh

validate:
	@./scripts/validate.sh

validate-aws:
	@./scripts/aws/validate-sam.sh

generate-templates:
	@./scripts/generate-templates.sh --all

generate-all: generate-templates index validate

local-smoke:
	@test -n "$(APP)" || (echo "usage: make local-smoke APP=<app-id>" && exit 2)
	@./scripts/local-smoke.sh "$(APP)"

local-smoke-all:
	@./scripts/local-smoke.sh --all

local-smoke-certified:
	@./scripts/local-smoke.sh --all --tier certified
