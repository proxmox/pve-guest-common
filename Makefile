PACKAGE=libpve-guest-common-perl
PKGVER=2.0
PKGREL=3

DEB=${PACKAGE}_${PKGVER}-${PKGREL}_all.deb

DESTDIR=

PERL5DIR=${DESTDIR}/usr/share/perl5
DOCDIR=${DESTDIR}/usr/share/doc/${PACKAGE}

all:

.PHONY: deb
deb: ${DEB}
${DEB}:
	rm -rf build
	rsync -a * build
	cd build; dpkg-buildpackage -b -us -uc
	lintian ${DEB}

install: PVE
	install -d ${PERL5DIR}/PVE
	install -m 0644 PVE/AbstractConfig.pm ${PERL5DIR}/PVE/
	install -m 0644 PVE/AbstractMigrate.pm ${PERL5DIR}/PVE/
	install -m 0644 PVE/ReplicationConfig.pm ${PERL5DIR}/PVE/
	install -d ${PERL5DIR}/PVE/VZDump
	install -m 0644 PVE/VZDump/Plugin.pm ${PERL5DIR}/PVE/VZDump/

.PHONY: upload
upload: ${DEB}
	tar cf - ${DEB} | ssh repoman@repo.proxmox.com -- upload --product pve --dist stretch

distclean: clean

clean:
	rm -rf ./build *.deb *.changes

.PHONY: dinstall
dinstall: ${DEB}
	dpkg -i ${DEB}
