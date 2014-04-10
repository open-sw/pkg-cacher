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

use parent qw(Class::Accessor Repos);

use File::Basename 'dirname';

use constant {
	RELEASE_RE => qr/^ [[:xdigit:]]{32} +[0-9]+ (.*)$/,
	PACKAGES_FILE_RE => qr/\/Packages(\.bz2|\.gz)?$/,
	PACKAGES_RE => qr/^Filename: (.*)$/,
	SOURCES_FILE_RE => qr/\/Sources(\.bz2|\.gz)?$/,
	SOURCES_RE => qr/^ [[:xdigit:]]{32} +[0-9]+ (.*)$/,
	INDEX_FILE_RE => qr/\/Index(\.bz2|\.gz)?$/,
	INDEX_RE => qr/^ [[:xdigit:]]{40} +[0-9]+ (.*)$/,
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
		my $rootpath = rootpath($dirname.'/'.$file);

		if (defined $rootpath) {
			if (-f $file.'/InRelease' || (-f $file.'/Release' && -f $file.'/Release.gpg')) {
				$repo = $class->new({path => $dirname.'/'.$file, verbose => $verbose});
			}
		}
	}
	return $repo;
}

sub process {
	my ($self, $files) = @_;

	print 'Processing debian repository = '.$self->path."\n" if $self->verbose;

	my $inrelease_status = $self->validate($files, 'InRelease');
	my $release_status = $self->validate($files, 'Release');

	my $gpg_status = $self->validate($files, 'Release.gpg');
	$self->prune_file_lists($files, 'Release.gpg', $gpg_status);

	if ($inrelease_status != 0 && $release_status != 0) {
		return 0;
	}

	$self->prune_file_lists($files, 'InRelease', $inrelease_status);

	$self->prune_file_lists($files, 'Release', $release_status);
	
	if (open(my $fh, '<', $self->cached_file($self->fullpath($inrelease_status == 0 ? 'InRelease' : 'Release')))) {
		while (<$fh>) {
			chomp;
			if ($_ =~ RELEASE_RE) {
				my $filename = $1;

				my $status = $self->validate($files, $filename);
				
				$self->prune_file_lists($files, $filename, $status);

				if ($status == 0) {
					if ($filename =~ PACKAGES_FILE_RE) {
						$self->process_packages($filename, $files);
					} elsif ($filename =~ INDEX_FILE_RE) {
						$self->process_index($filename, $files);
					} elsif ($filename =~ SOURCES_FILE_RE) {
						$self->process_sources($filename, $files);
					}
				}
			}
		}
	}

	return 1;
}

sub process_packages {
	my ($self, $file, $file_lists) = @_;

	my $rootpath = rootpath($self->path);

	my $pkg = $self->open_compressed($self->cached_file($self->fullpath($file)));

	while (<$pkg>) {
		chomp;
		if ($_ =~ PACKAGES_RE) {
			my $filename = $1;

			my $status = $self->validate($file_lists, $filename, $rootpath);
			
			$self->prune_file_lists($file_lists, $filename, $status, $rootpath);
		}
	}

	$pkg->close();
}

sub process_sources {
	my ($self, $file, $file_lists) = @_;

	my $rootpath = rootpath($self->path);

	my $src = $self->open_compressed($self->cached_file($self->fullpath($file)));

	my $curdir;
	my @files = ();
	my $filesvalues = 0;

	while (<$src>) {
		chomp;
		if ($_ eq '') {
			foreach my $filename ( @files ) {
				my $filepath = $curdir.'/'.$filename;

				my $status = $self->validate($file_lists, $filepath, $rootpath);

				$self->prune_file_lists($file_lists, $filepath, $status, $rootpath);
			}

			$curdir = undef;
			$filesvalues = 0;
			@files = ();
		} elsif (/^([[:alpha:]-]+):( (.*))?$/) {
			my $key = $1;
			my $value = $3;

			$filesvalues = 0;
			if ($key eq 'Directory') {
				$curdir = $value;
			} elsif ($key eq 'Files') {
				$filesvalues = 1;
			} 
		} elsif ($filesvalues && $_ =~ SOURCES_RE) {
			push @files, $1;
		}
	}

	$src->close();
}

sub process_index {
	my ($self, $file, $file_lists) = @_;

	my $index = $self->open_compressed($self->cached_file($self->fullpath($file)));
	my $dirname = dirname($file);

	while (<$index>) {
		chomp;
		if ($_ =~ INDEX_RE) {
			my $filename = $dirname.'/'.$1;

			my $status = $self->validate($file_lists, $filename);
			
			$self->prune_file_lists($file_lists, $filename, $status);
		}
	}

	$index->close();
}

1;
