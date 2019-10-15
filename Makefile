include /usr/share/dpkg/pkg-info.mk

PACKAGE=libpve-guest-common-perl

DEB=${PACKAGE}_${DEB_VERSION_UPSTREAM_REVISION}_all.deb
DSC=${PACKAGE}_${DEB_VERSION_UPSTREAM_REVISION}.dsc

BUILDDIR ?= ${PACKAGE}-${DEB_VERSION_UPSTREAM}

DESTDIR=

PERL5DIR=${DESTDIR}/usr/share/perl5
DOCDIR=${DESTDIR}/usr/share/doc/${PACKAGE}

all:

${BUILDDIR}:
	rm -rf ${BUILDDIR}
	rsync -a * ${BUILDDIR}
	echo "git clone git://git.proxmox.com/git/pve-guest-common.git\\ngit checkout ${GITVERSION}" > ${BUILDDIR}/debian/SOURCE

.PHONY: deb
deb: ${DEB}
${DEB}: ${BUILDDIR}
	cd ${BUILDDIR}; dpkg-buildpackage -b -us -uc
	lintian ${DEB}

.PHONY: dsc
dsc: ${DSC}
${DSC}: ${BUILDDIR}
	cd ${BUILDDIR}; dpkg-buildpackage -S -us -uc -d -nc
	lintian ${DSC}

install: PVE
	install -d ${PERL5DIR}/PVE
	install -m 0644 PVE/GuestHelpers.pm ${PERL5DIR}/PVE/
	install -m 0644 PVE/AbstractConfig.pm ${PERL5DIR}/PVE/
	install -m 0644 PVE/AbstractMigrate.pm ${PERL5DIR}/PVE/
	install -m 0644 PVE/ReplicationConfig.pm ${PERL5DIR}/PVE/
	install -m 0644 PVE/ReplicationState.pm ${PERL5DIR}/PVE/
	install -m 0644 PVE/Replication.pm ${PERL5DIR}/PVE/
	install -d ${PERL5DIR}/PVE/VZDump
	install -m 0644 PVE/VZDump/Plugin.pm ${PERL5DIR}/PVE/VZDump/
	install -m 0644 PVE/VZDump/Common.pm ${PERL5DIR}/PVE/VZDump/

.PHONY: upload
upload: ${DEB}
	tar cf - ${DEB} | ssh repoman@repo.proxmox.com -- upload --product pve --dist buster

distclean: clean

clean:
	rm -rf ${BUILDDIR} *.deb *.dsc *.changes *.buildinfo *.tar.gz

.PHONY: dinstall
dinstall: ${DEB}
	dpkg -i ${DEB}
