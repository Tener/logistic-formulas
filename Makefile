.PHONY: all test package install play

all: test

test:
	./tools/test.sh

package:
	./tools/package.sh

install:
	./tools/install.sh

play:
	./tools/factorio-test.sh --play mods/ logistic-formulas/playtest
