#! /usr/bin/perl
# vim: ts=4 sw=4 ai si
#
# Copyright (C) 2008-2013 Robert Nelson <robertn@the-nelsons.org>
#
# This is a library file for Pkg-cacher to allow code
# common to Pkg-cacher itself plus its supporting scripts
# (pkg-cacher-report.pl and pkg-cacher-cleanup.pl) to be
# maintained in one location.

# This function reads the given config file into the
# given hash ref. The key and value are separated by
# a '=' and will have all the leading and trailing
# spaces removed.

package Repos::Debian;

use strict;
use warnings;

use Class::Accessor 'antlers';

require Repos;
extends 'Repos';

use constant {
	RELEASE_FILE => 'Release',
	RELEASE_RE => qr/^ [0-9a-f]{32} +[0-9]+ (.*)$/,
	PACKAGES_FILE_RE => qr/\/Packages(\.bz2|\.gz)?$/,
	PACKAGES_RE => qr/^Filename: (.*)$/,
};

sub rootpath {
	my ($file) = @_;

	my @dirs = split('/', $file);

	if ($#dirs >= 2 && $dirs[-2] eq 'dists') {
		return ($#dirs >= 3) ? join('/', @dirs[0, -3]) : $dirs[0];
	} else {
		return undef;
	}
}

sub checkrepo {
	my ($class, $file, $dirname, $verbose) = @_;
	my $repo;

	if (defined $dirname) {
		my $rootpath = rootpath($dirname);

		if (defined $rootpath) {
			if (-f $file && ($file eq 'InRelease' || ($file eq 'Release' && -f 'Release.gpg'))) {
				$repo = $class->new({path => $dirname, verbose => $verbose});
			}
		}
	}
	return $repo;
}

sub process {
	my ($self, $files) = @_;

	print 'Processing debian repository = '.$self->path."\n" if $self->verbose;

	my $status = $self->validate(RELEASE_FILE);
	
	if ($status != 0) {
		return 0;
	}

	$self->prune_file_lists($files, RELEASE_FILE, $status);

	$status = $self->validate(RELEASE_FILE.'.gpg');
	$self->prune_file_lists($files, RELEASE_FILE.'.gpg', $status);
	
	if (open(my $fh, '<', $self->cached_file($self->fullpath(RELEASE_FILE)))) {
		while (<$fh>) {
			if ($_ =~ RELEASE_RE) {
				my $filename = $1;

				my $status = $self->validate($filename);
				
				$self->prune_file_lists($files, $filename, $status);

				if ($status == 0 && $filename =~ PACKAGES_FILE_RE) {
					$self->process_packages($filename, $files);
				}
			}
		}
	}

	return 1;
}

sub process_packages {
	my ($self, $file, $file_lists) = @_;

	my $status = $self->validate($file);
	
	$self->prune_file_lists($file_lists, $file, $status);

	my $rootpath = rootpath($self->path);

	my $pkg;

	if ($file =~ /\.bz2$/) {
		$pkg = IO::Uncompress::Bunzip2->new($self->cached_file($self->fullpath($file)));
	} elsif ($file =~ /\.gz$/) {
		$pkg = IO::Uncompress::Gunzip->new($self->cached_file($self->fullpath($file)));
	} else {
		open($pkg, '<', $self->cached_file($self->fullpath($file)));
	}

	while (<$pkg>) {
		if ($_ =~ PACKAGES_RE) {
			my $filename = $1;

			my $status = $self->validate($filename, $rootpath);
			
			$self->prune_file_lists($file_lists, $filename, $status, $rootpath);
		}
	}

	$pkg->close();
}

1;
