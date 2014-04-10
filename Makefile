NAME=pkg-cacher
VERSION=1.1.0
TAROPTS=--directory .. --exclude=.git --exclude=.svn --exclude='*.swp' --exclude='*~' --dereference 

PROGRAM_FILES=pkg-cacher pkg-cacher.pl pkg-cacher-request.pl pkg-cacher-fetch.pl \
			pkg-cacher-lib.pl \
			pkg-cacher-cleanup.pl \
			pkg-cacher-report.pl \
			Repos.pm
REPOS_FILES=Repos/Debian.pm Repos/Fedora.pm
DATA_FILES=index_files.regexp static_files.regexp
CLIENT_SAMPLE_FILES=client-samples/pkg-cacher-debian.list client-samples/pkg-cacher-ubuntu.list \
	client-samples/pkg-cacher-centos.repo client-samples/pkg-cacher-fedora.repo \

DESTDIR:=$(shell pwd)/../dist

$(DESTDIR):
	test -d $@ || mkdir $@

$(DESTDIR)/debian: $(DESTDIR)
	test -d $@ || mkdir $@

$(DESTDIR)/$(NAME): $(DESTDIR)
	test -d $@ || mkdir $@

tar: $(DESTDIR)/$(NAME)
	( \
	sed -e "s/@@VERSION@@/$(VERSION)/" < fedora/$(NAME).spec.in > fedora/$(NAME).spec; \
	ln -sf `pwd` ../$(NAME)-$(VERSION); \
	tar -cjf $(DESTDIR)/$(NAME)/$(NAME)-$(VERSION).tar.bz2 $(TAROPTS) $(NAME)-$(VERSION); \
	tar -czf $(DESTDIR)/$(NAME)/$(NAME)-$(VERSION).tar.gz  $(TAROPTS) $(NAME)-$(VERSION); \
	rm -f ../$(NAME)-$(VERSION); \
	)

rpms: tar
	( \
	SRPMDIR=`rpm --eval '%{_srcrpmdir}'`; \
	RPMDIR=`rpm --eval '%{_rpmdir}'`; \
	rpmbuild --define "dist %{nil}" -ta $(DESTDIR)/$(NAME)/$(NAME)-$(VERSION).tar.bz2; \
	mv $$SRPMDIR/$(NAME)-*$(VERSION)*.src.rpm $(DESTDIR)/$(NAME); \
	mv $$RPMDIR/noarch/$(NAME)-*$(VERSION)*.noarch.rpm $(DESTDIR)/$(NAME); \
	)

debs: $(DESTDIR)/debian
	dpkg-buildpackage -I.svn -I.git -us -uc
	mv ../$(NAME)*_$(VERSION)* $(DESTDIR)/debian

clean:
	test -n "$(DESTDIR)" && rm -rf $(DESTDIR)/$(NAME)

# These install-* rules mimic the corresponding dh_* utilities provided by Debian debhelper.
install-dirs:
	install -m 755 -d $(DESTDIR)/usr/sbin
	install -m 755 -d $(DESTDIR)/usr/share/pkg-cacher
	install -m 755 -d $(DESTDIR)/usr/share/pkg-cacher/Repos
	install -m 755 -d $(DESTDIR)/var/cache/pkg-cacher
	install -m 755 -d $(DESTDIR)/var/log/pkg-cacher

install-config:
	install -m 755 -d $(DESTDIR)/etc/pkg-cacher
	install -m 644 pkg-cacher.conf $(DESTDIR)/etc/pkg-cacher/pkg-cacher.conf
	install -m 644 apache.conf $(DESTDIR)/etc/pkg-cacher/apache.conf

install-cron:
	install -m 755 -d $(DESTDIR)/etc/cron.daily
	install -m 755 pkg-cacher.cron.daily $(DESTDIR)/etc/cron.daily/pkg-cacher

install-init:
	install -m 755 -d $(DESTDIR)/etc/init.d
	install -m 755 -d $(DESTDIR)/etc/sysconfig
	install -m 755 fedora/pkg-cacher.init $(DESTDIR)/etc/init.d/pkg-cacher
	install -m 644 fedora/pkg-cacher.sysconfig $(DESTDIR)/etc/sysconfig/pkg-cacher

install-docs:
	install -m 755 -d $(DESTDIR)/usr/share/doc/pkg-cacher
	install -m 755 -d $(DESTDIR)/usr/share/doc/pkg-cacher/client-samples
	install -m 644 README TODO $(DESTDIR)/usr/share/doc/pkg-cacher
	install -m 644 $(CLIENT_SAMPLE_FILES) $(DESTDIR)/usr/share/doc/pkg-cacher/client-samples

install-logrotate:
	install -m 755 -d $(DESTDIR)/etc/logrotate.d
	install -m 644 pkg-cacher.logrotate $(DESTDIR)/etc/logrotate.d/pkg-cacher

install-man:
	install -m 755 -d $(DESTDIR)/usr/share/man/man1
	install -m 644 debian/pkg-cacher.1 $(DESTDIR)/usr/share/man/man1/pkg-cacher.1

install-link:
	ln -sf ../share/pkg-cacher/pkg-cacher $(DESTDIR)/usr/sbin/pkg-cacher 

install-files:
	install -m 755 $(PROGRAM_FILES) $(DESTDIR)/usr/share/pkg-cacher
	install -m 755 $(REPOS_FILES) $(DESTDIR)/usr/share/pkg-cacher/Repos
	install -m 644 $(DATA_FILES) $(DESTDIR)/usr/share/pkg-cacher

install-clean:
	test -n "$(DESTDIR)" && rm -rf $(DESTDIR)
	rm -f fedora/$(NAME).spec

.PHONY: all tar rpms debs $(DESTDIR) $(DESTDIR)/$(NAME) \
	install-dirs install-config install-cron install-init install-logrotate \
	install-man install-link install-files install-clean
