
all:

.PHONY: check abstract-config config-reservation guest-id hookscript storage-tunnel
check: abstract-config config-reservation guest-id hookscript storage-tunnel

abstract-config: abstract-config-tests.pl
	perl -I.. ./abstract-config-tests.pl

config-reservation: config-reservation-tests.pl
	perl -I.. ./config-reservation-tests.pl

guest-id: guest-id-tests.pl
	perl -I.. ./guest-id-tests.pl

hookscript: hookscript-tests.pl
	perl -I.. ./hookscript-tests.pl

storage-tunnel: storage-tunnel-tests.pl
	perl -I.. ./storage-tunnel-tests.pl
