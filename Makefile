.PHONY: test test-fast

test:
	uv run pytest -v

test-fast:
	uv run pytest -v -m "not slow"
