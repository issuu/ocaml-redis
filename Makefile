.PHONY: build test clean
build:
	jbuilder build @install --dev

test:
	jbuilder runtest

clean:
	jbuilder clean
