.PHONY: index validate validate-aws

index:
	@./scripts/build-index.sh

validate:
	@./scripts/validate.sh

validate-aws:
	@./scripts/aws/validate-sam.sh
