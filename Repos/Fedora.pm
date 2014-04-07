#! /usr/bin/perl
# vim: ts=4 sw=4 ai si
#
# Copyright (C) 2008-2013 Robert Nelson <robertn@the-nelsons.org>
#
# This module handles Fedora repositories.

# 	The directory tree is scanned for headers/*/repodata/repomd.xml files.
# 		The * portion is treated as repo-root, hashes each containing all the files in one of headers, packages and private are built.
# 		The repomd.xml file is validated and if valid it is removed from the file list hashes.
# 			Validation includes:
# 				checking private/[repo-root]/repodata/repomd.xml.complete
# 				test ability to lock the packages[repo-root]/repodata/repomd.xml
# 		If the repomd.xml fails validation:
# 			an error message is logged
# 			processing continues looking for another repository.
# 		The repomd.xml file is parsed.
# 		Each file referenced in repomd.xml is tested
# 			If the file passes validation:
# 				if tag data attribute type is primary_db or primary, remember it
# 				If the file is [hash]-primary.sqlite.bz2 or primary.sqlite.bz2 or primary.xml.gz or primary.xml remember it
# 				Remove it from the hashes
# 			If it is being processed:
# 				Remove it from the hashes
# 		The primary.xml.gz or primary.xml is parsed (It is assumed that they are the same or if not that the compressed version is more accurate)
# 		For each package:
# 			Validate file referenced in href attribute of location
# 			If the file passes validation or is being processed
# 				Remove it from the hashes
# 		Delete all files still remaining in the hashes
# 	The global lock is released

package Repos::Fedora;

use strict;
use warnings;

use Class::Accessor qw(antlers);

require Repos;
extends 'Repos';

require DBI;
require XML::Simple;
require XML::Twig;

use constant {
	REPOMD_FILE => 'repodata/repomd.xml',
};

sub checkrepo {
	my ($class, $file, $dirname, $verbose) = @_;
	my $repo;

	if ($file eq 'repodata' && -d $file && -f REPOMD_FILE) {
		$repo = $class->new({path => $dirname, verbose => $verbose});
	}
	return $repo;
}

sub process {
	my ($self, $files) = @_;

	print 'Processing fedora repository = '.$self->path."\n" if $self->verbose;

	my $status = $self->validate($files, REPOMD_FILE);
	
	if ($status != 0) {
		return 0;
	}

	$self->prune_file_lists($files, REPOMD_FILE, $status);

	$self->process_repomd($files);

	return 1;
}

sub process_repomd {
	my ($self, $files) = @_;

	my $xs = XML::Simple::->new();
	my $repomd = $xs->XMLin($self->cached_file($self->fullpath(REPOMD_FILE)));
	my $prestodelta_file;
	my $primary_db_file;
	my $primary_file;

	foreach my $item (@{$repomd->{'data'}}) {
		my $type = $item->{'type'};
		my $location = $item->{'location'}{'href'};

		my $status = $self->validate($files, $location);
		
		$self->prune_file_lists($files, $location, $status);

		if ($status == 0) {
			$prestodelta_file = $location if ($type eq 'prestodelta');
			$primary_file = $location if ($type eq 'primary');
			$primary_db_file = $location if ($type eq 'primary_db');
		}
	}

	if (defined $prestodelta_file) {
		$self->process_prestodelta($prestodelta_file, $files);
	}

	if (defined $primary_db_file) {
		$self->process_primary_db($primary_db_file, $files);
	} elsif (defined $primary_file) {
		$self->process_primary($primary_file, $files);
	}
}

sub process_prestodelta {
	my ($self, $file, $file_lists) = @_;

	my $filename_cb = sub {
		my ($t, $elt) = @_;
		my $filename = $elt->text;

		my $status = $self->validate($file_lists, $filename);
		
		$self->prune_file_lists($file_lists, $filename, $status);

		$t->purge();

		1;
	};

	my $twig = XML::Twig->new(twig_handlers => { 'filename' => $filename_cb });
	my $gz;
	my $prestodelta;

	if ($file =~ /\.gz$/) {
		$gz = IO::Uncompress::Gunzip->new($self->cached_file($self->fullpath($file)));
		$prestodelta = $twig->parse($gz);
	} else {
		$prestodelta = $twig->parse($self->cached_file($self->fullpath($file)));
	}
}

sub process_primary {
	my ($self, $file, $file_lists) = @_;

	my $location_cb = sub {
		my ($t, $elt) = @_;
		my $location = $elt->att('href');

		my $status = $self->validate($file_lists, $location);
		
		$self->prune_file_lists($file_lists, $location, $status);

		$t->purge();

		1;
	};

	my $twig = XML::Twig->new(twig_handlers => { 'package/location' => $location_cb });

	if ($file =~ /\.gz$/) {
		my $gz = IO::Uncompress::Gunzip->new($self->cached_file($self->fullpath($file)));
		$twig->parse($gz);
		$gz->close();
	} else {
		$twig->parse($self->cached_file($self->fullpath($file)));
	}
}

sub process_primary_db {
	my ( $self, $file, $file_lists ) = @_;

	my $db_file = $self->cached_file($self->fullpath($file));
	my $temp_file = $self->copy_compressed($db_file, 'temp');

	$db_file = $temp_file if defined $temp_file;

	my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file","","");

	my $sth = $dbh->prepare('select location_href from packages');

	$sth->execute();

	while (my @row = $sth->fetchrow_array()) {
		my $location = $row[0];

		my $status = $self->validate($file_lists, $location);
		
		$self->prune_file_lists($file_lists, $location, $status);
	};
}

1;
