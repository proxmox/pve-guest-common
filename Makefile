include /usr/share/dpkg/pkg-info.mk

PACKAGE=libpve-guest-common-perl

DEB=${PACKAGE}_${DEB_VERSION_UPSTREAM_REVISION}_all.deb
DSC=${PACKAGE}_${DEB_VERSION_UPSTREAM_REVISION}.dsc

BUILDDIR ?= ${PACKAGE}-${DEB_VERSION_UPSTREAM}

all:

${BUILDDIR}:
	rm -rf ${BUILDDIR}
	cp -a src ${BUILDDIR}
	cp -a debian ${BUILDDIR}/
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

.PHONY: upload
upload: ${DEB}
	tar cf - ${DEB} | ssh repoman@repo.proxmox.com -- upload --product pve --dist bullseye

distclean: clean

clean:
	rm -rf ${BUILDDIR} *.deb *.dsc *.changes *.buildinfo *.tar.gz

.PHONY: dinstall
dinstall: ${DEB}
	dpkg -i ${DEB}
