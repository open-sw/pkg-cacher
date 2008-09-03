Summary:  A cacheing tool for the apt-get package management system.
Name: apt-cacher
Version: 1
Release: 4.1
Copyright:GPL
Group: Applications/System
Source:http://ftp.debian.org/debian/pool/main/a/apt-cacher/apt-cacher_1.4.1.tar.gz
URL:http://www.nick-andrew.net/projects/apt-cacher/
Packager: Srimal Jayawardena (srimal at linux dot lk)(srimalj at gmail dot com) 



%description
apt-cacher.pl is a CGI which will keep a cache on disk of Debian Packages and Release files (including .deb files) which have been received from Debian distribution servers on the Internet. When an apt-get client issues a request for a file to apt-cacher.pl, if the file is already on disk it is served to the client immediately, otherwise it is fetched from the Internet, saved on disk, and then served to the client. This means that several Debian machines can be upgraded but each package need be downloaded only once.

This requires the apache web server version 2 to be installed (www.apache.org) 

%files
/usr/share/apt-cacher/
/etc/apt-cacher/
/etc/httpd/conf.d/z-apt-cacher.conf
/etc/cron.daily/apt-cacher

%post 
/usr/share/apt-cacher/install.pl
mkdir /var/cache/apt-cacher/
mkdir /var/log/apt-cacher/
chown -R apache /var/log/apt-cacher/
chown -R apache /var/cache/apt-cacher/

%clean
rm -rf /var/cache/apt-cacher/ /var/log/apt-cacher/
rm -rf /usr/share/apt-cacher/
rm -rf /etc/apt-cacher/
rm -rf /etc/httpd/conf.d/z-apt-cacher.conf
rm -rf /etc/cron.daily/apt-cacher


%changelog
* Wed Jan 25 2006 Srimal Jayawardena ( srimalj@gmail.com )
-  modified $version in /usr/share/apt-cacher/apt-cacher to show 1.4.2 which was still showing 0.1
