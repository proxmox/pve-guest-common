include /usr/share/dpkg/pkg-info.mk

PACKAGE=libpve-guest-common-perl

DEB=$(PACKAGE)_$(DEB_VERSION)_all.deb
DSC=$(PACKAGE)_$(DEB_VERSION).dsc

BUILDDIR ?= $(PACKAGE)-$(DEB_VERSION)

all:

.PHONY: tidy
tidy:
	git ls-files ':*.p[ml]'| xargs -n4 -P0 proxmox-perltidy

$(BUILDDIR):
	rm -rf $@ $@.tmp
	cp -a src $@.tmp
	cp -a debian $@.tmp/
	echo "git clone git://git.proxmox.com/git/pve-guest-common.git\\ngit checkout $(GITVERSION)" > $@.tmp/debian/SOURCE
	mv $@.tmp $@

.PHONY: deb
deb: $(DEB)
$(DEB): $(BUILDDIR)
	cd $(BUILDDIR); dpkg-buildpackage -b -us -uc
	lintian $(DEB)

.PHONY: dsc
dsc:
	$(MAKE) $(DSC)
	lintian $(DSC)

$(DSC): $(BUILDDIR)
	cd $(BUILDDIR); dpkg-buildpackage -S -us -uc -d -nc

sbuild: $(DSC)
	sbuild $(DSC)

.PHONY: upload
upload: UPLOAD_DIST ?= $(DEB_DISTRIBUTION)
upload: $(DEB)
	tar cf - $(DEB) | ssh repoman@repo.proxmox.com -- upload --product pve --dist $(UPLOAD_DIST)

distclean: clean
clean:
	rm -rf $(PACKAGE)-[0-9]*/ *.deb *.dsc *.changes *.buildinfo *.build $(PACKAGE)*.tar*

.PHONY: dinstall
dinstall: $(DEB)
	dpkg -i $(DEB)
