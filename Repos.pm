#! /usr/bin/perl
# vim: ts=4 sw=4 ai si
#
# Copyright (C) 2008-2013 Robert Nelson <robertn@the-nelsons.org>
#
# This module is the base class for repositories.

package Repos;

use strict;
use warnings;

use parent qw(Class::Accessor);

#	has path => ( is => 'ro', isa => 'Str' )";
#	has verbose => ( is => 'rw', isa => 'Boolean' )";

Repos->mk_accessors(qw(path verbose));

use File::Basename;

require	IO::Uncompress::Bunzip2;
require	IO::Uncompress::Gunzip;
require	IO::Uncompress::UnXz;

use Fcntl qw/:DEFAULT :flock/;

sub fullpath {
	my ($self, $file) = @_;

	return $self->path.'/'.$file;
}

sub headers_file {
	my ($self, $fullpath) = @_;

	return 'headers/'.$fullpath;
}

sub cached_file {
	my ($self, $fullpath) = @_;

	return 'packages/'.$fullpath;
}

sub complete_file {
	my ($self, $fullpath) = @_;

	return 'private/'.$fullpath.'.complete';
}

sub open_compressed {
	my ($self, $file) = @_;

	my ( $extension ) = $file =~ qr/(\.bz2|\.gz|\.xz)$/;

	my $fh;

	if ($extension) {
		if ($extension eq '.bz2') {
			$fh = IO::Uncompress::Bunzip2->new($file);
		} elsif ($extension eq '.gz') {
			$fh = IO::Uncompress::Gunzip->new($file);
		} elsif ($extension eq '.xz') {
			$fh = IO::Uncompress::UnXz->new($file);
		}
	} else {
		open($fh, '<', $file);
	}

	return $fh;
}

sub copy_compressed {
	my ( $self, $infile, $outdir ) = @_;

	my ( $file, undef, $extension ) = fileparse($infile, ('.bz2', '.gz', '.xz'));

	if ($extension) {
		my $outfile = $outdir.'/'.$file;

		if ($extension eq '.bz2') {
			# print 'Bunzipping '.$infile.' to '.$outfile."\n" if $self->verbose;
			IO::Uncompress::Bunzip2::bunzip2($infile, $outfile);
		} elsif ($extension eq '.gz') {
			# print 'Bunzipping '.$infile.' to '.$outfile."\n" if $self->verbose;
			IO::Uncompress::Gunzip::gunzip($infile, $outfile);
		} elsif ($extension eq '.xz') {
			# print 'Unlzmaing '.$infile.' to '.$outfile."\n" if $self->verbose;
			IO::Uncompress::UnXz::unxz($infile, $outfile);
		}
		return $outfile;
	} else {
		return undef;
	}
}

sub validate {
	my ($self, $file_lists, $file, $rootpath) = @_;

	my $status = -1;

	my $fullpath = $rootpath ? $rootpath.'/'.$file : $self->fullpath($file);

	if (defined $file_lists->{'headers'}{$fullpath}) {
		if (defined $file_lists->{'private'}{$fullpath.'.complete'}) {
			if (defined $file_lists->{'packages'}{$fullpath}) {
				# Everything ok
				$status = 0;
			} else {
				# Complete file but no package
				$status = 4;
			}
		} else {
			my $pkgfile;

			if (sysopen($pkgfile, $self->cached_file($fullpath), O_RDONLY)) {
				# a fetcher was either not successful or is still running
				# look for activity...
				if (flock($pkgfile, LOCK_EX|LOCK_NB)) {
					flock($pkgfile, LOCK_UN);
					# fetcher died 
					$status = 3;
				} else {
					# fetcher active
					$status = 1;
				}
				close($pkgfile);
			} else {
				# headers only and no fetcher running probably error status
				$status = 2;
			}
		}
	} else {
		# No headers any other files are zombies
		$status = 5;
	}
	return $status;
}

sub prune_file_lists {
	my ($self, $file_lists, $file, $status, $rootpath) = @_;

	my $fullpath = $rootpath ? $rootpath.'/'.$file : $self->fullpath($file);

	if ($status < 3) {
		delete $file_lists->{'headers'}{$fullpath};
		if ($status < 2) {
			delete $file_lists->{'packages'}{$fullpath};
			if ($status < 1) {
				delete $file_lists->{'private'}{$fullpath.'.complete'};
			}
		}
	}
}

1;
