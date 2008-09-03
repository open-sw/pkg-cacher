#!/usr/bin/perl

# apt-cacher-import.pl
# Script to import .deb packages into the Apt-cacher package caching system.
# This script does not need to be run when setting up Apt-cacher for the first
# time: its purpose is to initialise .deb packages that have been copied in
# from some other source, such as a local mirror. Apt-cacher doesn't store
# it's cached .debs in plain format, it prepends HTTP headers to them to send
# out to clients when a package is requested. It also keeps track of which
# packages are fully downloaded by touching a '.complete' file in the 'private'
# directory in the cache. If .debs are just copied straight into the cache
# dir Apt-cacher won't use them because it thinks they are both corrupt (no
# headers) and incomplete (no .complete file). This script allows you to
# copy a bunch of .debs into an import dir, then run this script to prepend
# the HTTP headers and touch the .complete file after moving them to the cache
# dir.
#
# Usage:
# 1. Place your plain debs into /var/cache/apt-cacher/import (or where-ever
#    you set the cache dir to be)
# 2. Run this script: /usr/share/apt-cacher-import.pl
#
# Copyright (C) 2004, Jonathan Oxer <jon@debian.org>
# Copyright (C) 2005, Eduard Bloch <blade@debian.org>

# Distributed under the terms of the GNU Public Licence (GPL).

#use strict;
#############################################################################
### configuration ###########################################################
# Include the library for the config file parser
require '/usr/share/apt-cacher/apt-cacher-lib.pl';

use Getopt::Long qw(:config no_ignore_case bundling pass_through);
use File::Basename;
use File::Copy;
use Cwd 'abs_path';
use HTTP::Date;

use strict;
use warnings;

my $configfile = '/etc/apt-cacher/apt-cacher.conf';
my $help;
my $quiet; # both not used yet
my $noact;
my $recmode;
my $ro_mode;
my $symlink_mode;

my %options = (
    "h|help" => \$help,
    "q|quiet"           => \$quiet,
    "n|no-act"          => \$noact,
    "R|recursive"       => \$recmode,
    "r|readonly"       => \$ro_mode,
    "s|symlinks"       => \$symlink_mode,
    "c|cfgfile=s"        => \$configfile
);

&help unless ( GetOptions(%options));
&help if ($help);

#$configfile=abs_path($configfile);

our $cfg;
eval {
	$cfg = read_config($configfile);
};

# not sure what to do if we can't read the config file...
die "Could not read config file: $@" if $@;

# change uid and gid
setup_ownership($cfg);

my $private_dir = "$cfg->{cache_dir}/private";
my $import_dir = "$cfg->{cache_dir}/import";
my $target_dir = "$cfg->{cache_dir}/packages";
my $header_dir = "$cfg->{cache_dir}/headers";

my $packagesimported = 0;

#############################################################################

if(!$ARGV[0]) {
   syswrite(STDOUT, "No import directory specified as the first argument, using $import_dir\n") if !$quiet;
   sleep 2;
}
else {
   $import_dir=$ARGV[0];
}

die "Cannot write to $target_dir - permission denied?\n" if !-w $target_dir;
die "Cannot write to $header_dir - permission denied?\n" if !-w $header_dir;

# common for all files
my @info = stat($private_dir);
my $headerdate = time2str();

sub importrec {
    my $import_dir=shift;
    chdir($import_dir) || die "apt-cacher-import.pl: can't open the import directory ($import_dir)";
    #print "Entering: $import_dir\n";

    if($recmode) {
	my $cwd=Cwd::getcwd();
	for(<*>) {
	    if(-d $_ && ! -l $_) {
		importrec($_) if -d $_;
		chdir $cwd;
		#print "Back in $cwd\n";
	    }
	}
    }

    ### Loop through all the .debs in the import dir
    foreach my $packagefile ( <*.deb>, <*.udeb>, <*.dsc>, <*.diff.gz>, <*_*tar.gz>, <*diff.bz2>, <*_*.tar.bz2> ) {

	# Get some things we need to insert into the header
	my $headerlength = (stat($packagefile))[7];
	my $headeretag = int(rand(100000))."-".int(rand(1000))."-".int(rand(100000000));
	$headeretag =~ s/^\s*(.*?)\s*$/$1/;
	my $frompackagefile=$packagefile; # backup of the original name
	$packagefile=~s/_\d+%3a/_/;

	# Generate a header
	my $httpheader = "HTTP/1.1 200 OK
Date: ".$headerdate."
Server: Apache \(Unix\) apt-cacher
Last-Modified: ".$headerdate."
ETag: \"".$headeretag."\"
Accept-Ranges: bytes
Content-Length: ".$headerlength."
Keep-Alive: timeout=10, max=128
Connection: Keep-Alive
Content-Type: application/x-debian-package

"
; # there are TWO new lines

	# Then cat the header to a temp file
	print "Importing: $packagefile\n" if !$quiet;
	unlink "$header_dir/$packagefile", "$target_dir/$packagefile",  "$private_dir/$packagefile.complete"; # just to be sure
	if($symlink_mode) {
	    symlink(abs_path($frompackagefile), "$target_dir/$packagefile") ||
	    (unlink("$target_dir/$packagefile") && symlink(abs_path($frompackagefile), "$target_dir/$packagefile")) ||
	    die "Failed to create the symlink $target_dir/$packagefile";
	}
	elsif($ro_mode) {
	    link($frompackagefile, "$target_dir/$packagefile") || copy($frompackagefile, "$target_dir/$packagefile") || die "Failed to copy $frompackagefile";
	}
	else {
	    rename($frompackagefile, "$target_dir/$packagefile") || die "Failed to rename $frompackagefile. Try read-only (-r) or symlink (-s) options.";
	}

	open(my $headfile, ">$header_dir/$packagefile");
	print $headfile $httpheader;
	close $headfile;

	my $completefile = "$private_dir/$packagefile.complete";
	open(MF, ">$completefile");
	close(MF);
	# copy the ownership of the private directory
	chown $info[4], $info[5], "$header_dir/$packagefile", "$target_dir/$packagefile",  "$private_dir/$packagefile.complete";

	$packagesimported++;
    }
}

importrec($import_dir);

print "Done.\n" if !$quiet;
print "Packages imported: $packagesimported\n" if !$quiet;

# Woohoo, all done!
exit 0;

sub help {
    die "Usage: $0 [ -c apt-cacher.conf ] [ -q | --quiet ] [ -R | --recursive ] [ -r | --readonly ] [ -s | --symlinks ] [ package-source-dir ]

If -c is omited, '-c /etc/apt-cacher/apt-cacher.conf' is assumed.
If package-source-dir is omited, the filename from apt-cacher.conf is used.
-R descend into subdirectories to find source package files.
-r read but do not move the source files. Instead, create hardlinks or real copies.
-s create symlinks to the source files and not move them. If the
   target symlink exists, it will be removed.
";
}
