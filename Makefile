PACKAGE = pve-routedip
VERSION = $(shell dpkg-parsechangelog -S Version)
DEB = $(PACKAGE)_$(VERSION)_all.deb

DESTDIR =
PERLDIR = /usr/share/perl5
SBINDIR = /usr/sbin
SHAREDIR = /usr/share/$(PACKAGE)
WWWDIR = /usr/share/pve-manager/js

PERL_MODULES = \
	PVE/RoutedIP/Config.pm \
	PVE/RoutedIP/Runtime.pm \
	PVE/RoutedIP/Hooks.pm \
	PVE/RoutedIP/Daemon.pm \
	PVE/API2/RoutedIP.pm \
	PVE/API2/RoutedIP/VM.pm \
	PVE/CLI/pve_routedip.pm

all:

.PHONY: install
install:
	for m in $(PERL_MODULES); do install -D -m 0644 src/$$m $(DESTDIR)$(PERLDIR)/$$m; done
	# replace the modules diverted in preinst, see debian/pve-routedip.preinst
	install -D -m 0644 src/divert/PVE/Network.pm $(DESTDIR)$(PERLDIR)/PVE/Network.pm
	install -D -m 0644 src/divert/PVE/API2.pm $(DESTDIR)$(PERLDIR)/PVE/API2.pm
	install -D -m 0755 src/bin/pve-routedip $(DESTDIR)$(SBINDIR)/pve-routedip
	install -D -m 0755 src/bin/pve-routedipd $(DESTDIR)$(SBINDIR)/pve-routedipd
	install -D -m 0644 src/www/pve-routedip.js $(DESTDIR)$(WWWDIR)/pve-routedip.js
	install -D -m 0644 src/iproute2/pve-routedip.conf $(DESTDIR)/etc/iproute2/rt_protos.d/pve-routedip.conf
	install -d $(DESTDIR)$(SHAREDIR)
	sed -e 's/@VERSION@/$(VERSION)/' src/share/index-patch > $(DESTDIR)$(SHAREDIR)/index-patch
	chmod 0755 $(DESTDIR)$(SHAREDIR)/index-patch

.PHONY: check test
check test:
	prove -Isrc -v test/

.PHONY: deb
deb:
	dpkg-buildpackage -b -us -uc
	mv ../$(DEB) .
	rm -f ../$(PACKAGE)_$(VERSION)_*.buildinfo ../$(PACKAGE)_$(VERSION)_*.changes

.PHONY: clean
clean:
	rm -rf debian/$(PACKAGE) debian/.debhelper debian/files debian/*.substvars debian/*.debhelper debian/*.debhelper.log debian/debhelper-build-stamp
	rm -f $(PACKAGE)_*.deb
