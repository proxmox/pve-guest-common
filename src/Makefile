DESTDIR=
PERL5DIR=${DESTDIR}/usr/share/perl5
DOCDIR=${DESTDIR}/usr/share/doc/${PACKAGE}

all:

install: PVE
	install -d ${PERL5DIR}/PVE
	install -m 0644 PVE/GuestHelpers.pm ${PERL5DIR}/PVE/
	install -m 0644 PVE/AbstractConfig.pm ${PERL5DIR}/PVE/
	install -m 0644 PVE/AbstractMigrate.pm ${PERL5DIR}/PVE/
	install -m 0644 PVE/ReplicationConfig.pm ${PERL5DIR}/PVE/
	install -m 0644 PVE/ReplicationState.pm ${PERL5DIR}/PVE/
	install -m 0644 PVE/Replication.pm ${PERL5DIR}/PVE/
	install -m 0644 PVE/StorageTunnel.pm ${PERL5DIR}/PVE/
	install -m 0644 PVE/Tunnel.pm ${PERL5DIR}/PVE/
	install -d ${PERL5DIR}/PVE/VZDump
	install -m 0644 PVE/VZDump/Plugin.pm ${PERL5DIR}/PVE/VZDump/
	install -m 0644 PVE/VZDump/Common.pm ${PERL5DIR}/PVE/VZDump/

.PHONY: check
check:
	$(MAKE) -C tests check

.PHONY: clean
clean:
