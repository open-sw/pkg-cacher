#! /usr/bin/perl
# vim: ts=4 sw=4 ai si
#
# Copyright (C) 2008-2013 Robert Nelson <robertn@the-nelsons.org>
#
# This module is the base class for repositories.

package Repos;

use strict;
use warnings;

use Class::Accessor 'antlers';

has path => ( is => 'ro', isa => 'Str' );
has verbose => ( is => 'rw', isa => 'Boolean' );

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

sub validate {
	my ($self, $file, $rootpath) = @_;

	my $status = -1;

	my $fullpath = $rootpath ? $rootpath.'/'.$file : $self->fullpath($file);

	if (-f $self->headers_file($fullpath)) {
		if (-f $self->complete_file($fullpath)) {
			if (-f $self->cached_file($fullpath)) {
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
