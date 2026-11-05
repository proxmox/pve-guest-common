
all:

.PHONY: check abstract-config hookscript
check: abstract-config hookscript

abstract-config: abstract-config-tests.pl
	perl -I.. ./abstract-config-tests.pl

hookscript: hookscript-tests.pl
	perl -I.. ./hookscript-tests.pl
