
all:

.PHONY: check abstract-config guest-id hookscript storage-tunnel
check: abstract-config guest-id hookscript storage-tunnel

abstract-config: abstract-config-tests.pl
	perl -I.. ./abstract-config-tests.pl

guest-id: guest-id-tests.pl
	perl -I.. ./guest-id-tests.pl

hookscript: hookscript-tests.pl
	perl -I.. ./hookscript-tests.pl

storage-tunnel: storage-tunnel-tests.pl
	perl -I.. ./storage-tunnel-tests.pl
