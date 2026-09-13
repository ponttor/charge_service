.PHONY: install lint test coverage ci

install:
	bundle install

lint:
	bundle exec rubocop

test:
	bundle exec rake test

coverage: test
	@echo "Coverage report: coverage/index.html"
	@command -v open >/dev/null 2>&1 && open coverage/index.html || true

ci: lint test
