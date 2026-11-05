
all:

.PHONY: check abstract-config config-reservation firewall-config guest-id guest-identity hookscript storage-tunnel
check: abstract-config config-reservation firewall-config guest-id guest-identity hookscript storage-tunnel

abstract-config: abstract-config-tests.pl
	perl -I.. ./abstract-config-tests.pl

config-reservation: config-reservation-tests.pl
	perl -I.. ./config-reservation-tests.pl

firewall-config: firewall-config-tests.pl
	perl -I.. ./firewall-config-tests.pl

guest-id: guest-id-tests.pl
	perl -I.. ./guest-id-tests.pl

guest-identity: guest-identity-tests.pl
	perl -I.. ./guest-identity-tests.pl

hookscript: hookscript-tests.pl
	perl -I.. ./hookscript-tests.pl

storage-tunnel: storage-tunnel-tests.pl
	perl -I.. ./storage-tunnel-tests.pl
