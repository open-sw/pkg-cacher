#!/usr/bin/perl

`sed -e "s/# This line has been appended by the Apt-cacher install script/ /" /etc/apache/httpd.conf >/etc/apache/httpd.conf-temp`;
`mv /etc/apache/httpd.conf-temp /etc/apache/httpd.conf`;
