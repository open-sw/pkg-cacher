Summary:  A caching tool for the apt-get and yum package management system.
Name: pkg-cacher
Version: 0.9.2
Release: 1
License: GPL
Group: Applications/System
Source: %{name}-%{version}.tar.bz2
Packager: Robert Nelson (robertn at the-nelsons dot org)
Buildroot: %{_tmppath}/%{name}-%{version}-root
BuildArch: noarch
Provides: perl(pkg-cacher-lib.pl)

%description
pkg-cacher.pl is a CGI which will keep a cache on disk of Debian Packages and Release files (including .deb files) which have been received from Debian distribution servers on the Internet. When an apt-get client issues a request for a file to pkg-cacher.pl, if the file is already on disk it is served to the client immediately, otherwise it is fetched from the Internet, saved on disk, and then served to the client. This means that several Debian machines can be upgraded but each package need be downloaded only once.

This requires the apache web server version 2 to be installed (www.apache.org) 

%prep
%setup -q

%install
install -m 755 -d $RPM_BUILD_ROOT/usr/sbin
ln -sf   ../share/pkg-cacher/pkg-cacher $RPM_BUILD_ROOT/usr/sbin/pkg-cacher 
install -m 755 -d $RPM_BUILD_ROOT/etc/pkg-cacher
install -m 644 pkg-cacher.conf $RPM_BUILD_ROOT/etc/pkg-cacher/pkg-cacher.conf
install -m 644 apache.conf $RPM_BUILD_ROOT/etc/pkg-cacher/
install -m 755 -d $RPM_BUILD_ROOT/etc/cron.daily
install -m 755 pkg-cacher.cron.daily $RPM_BUILD_ROOT/etc/cron.daily/pkg-cacher
install -m 755 -d $RPM_BUILD_ROOT/etc/sysconfig
install -m 755 fedora/pkg-cacher.sysconfig $RPM_BUILD_ROOT/etc/sysconfig/pkg-cacher
install -m 755 -d $RPM_BUILD_ROOT/etc/init.d
install -m 755 fedora/pkg-cacher.init $RPM_BUILD_ROOT/etc/init.d/pkg-cacher
install -m 755 -d $RPM_BUILD_ROOT/etc/logrotate.d
install -m 755 pkg-cacher.logrotate $RPM_BUILD_ROOT/etc/logrotate.d/pkg-cacher
install -m 755 -d $RPM_BUILD_ROOT/usr/share/pkg-cacher
install -m 755 -d $RPM_BUILD_ROOT/var/log/pkg-cacher
install -m 755 -d $RPM_BUILD_ROOT/var/cache/pkg-cacher
install -m 755 pkg-cacher.pl $RPM_BUILD_ROOT/usr/share/pkg-cacher/
install -m 755 pkg-cacher2 $RPM_BUILD_ROOT/usr/share/pkg-cacher/pkg-cacher
install -m 755 pkg-cacher-report.pl $RPM_BUILD_ROOT/usr/share/pkg-cacher/
install -m 755 pkg-cacher-cleanup.pl $RPM_BUILD_ROOT/usr/share/pkg-cacher/
install -m 755 pkg-cacher-precache.pl $RPM_BUILD_ROOT/usr/share/pkg-cacher/
install -m 755 pkg-cacher-import.pl $RPM_BUILD_ROOT/usr/share/pkg-cacher/
install -m 755 pkg-cacher-lib.pl $RPM_BUILD_ROOT/usr/share/pkg-cacher/
perl -pe 's/^my \$version=.*/my \$version="'%{version}-%{release}'";/' -i $RPM_BUILD_ROOT/usr/share/pkg-cacher/*
install -m 755 -d $RPM_BUILD_ROOT/usr/share/man/man1
install -m 644 debian/pkg-cacher.1 $RPM_BUILD_ROOT/usr/share/man/man1/pkg-cacher.1

%files
%defattr(-,root,root)
/usr/sbin/pkg-cacher
%attr(-,pkg-cacher,pkg-cacher) %dir /usr/share/pkg-cacher
/usr/share/pkg-cacher/*
%attr(-,pkg-cacher,pkg-cacher) %dir /var/cache/pkg-cacher
%attr(-,pkg-cacher,pkg-cacher) %dir /var/log/pkg-cacher
%config /etc/pkg-cacher/pkg-cacher.conf
%config /etc/pkg-cacher/apache.conf
%config /etc/cron.daily/pkg-cacher
%config /etc/init.d/pkg-cacher
%config /etc/logrotate.d/pkg-cacher
%config /etc/sysconfig/pkg-cacher
%doc /usr/share/man/man1/pkg-cacher.*

%pre
getent group pkg-cacher > /dev/null || groupadd -r pkg-cacher
getent passwd pkg-cacher > /dev/null || \
	useradd -r -d /var/cache/pkg-cacher -g pkg-cacher -s /sbin/nologin \
	-c "pkg-cacher user" pkg-cacher > /dev/null 2>&1

%post
chkconfig pkg-cacher on
service pkg-cacher start

%clean
rm -rf $RPM_BUILD_ROOT

%changelog
* Mon Sep  1 2008 Robert Nelson ( robertn@the-nelsons.org )
  - Created from version 1.6.4 of apt-cacher.
