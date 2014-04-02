#!/usr/bin/perl

# pkg-cacher-cleanup.pl
# Script to clean the cache for the Pkg-cacher package caching system.
#
# Portions  (C) 2002, Jacob Lundberg <jacob@chaos2.org>
# Copyright (C) 2002-03, Jonathan Oxer <jon@debian.org>
# Copyright (C) 2005, Eduard Bloch <blade@debian.org>
# Copyright (C) 2008-2013 Robert Nelson <robertn@the-nelsons.org>
# Distributed under the terms of the GNU Public Licence (GPL).


# do locking, not losing files because someone redownloaded the index files
# right then

use strict;
use warnings;
use lib '/usr/share/pkg-cacher';

use Cwd;

## Just for testing!
#use File::Basename;
#use lib dirname(Cwd::abs_path $0);

use Getopt::Long qw(:config no_ignore_case bundling pass_through);
use Digest::SHA;
use HTTP::Date;

use File::Find;

my %files_lists = (
	headers => {},
	private => {},
	packages => {}
);


my $configfile = '/etc/pkg-cacher/pkg-cacher.conf';
my $nice_mode=0;
my $verbose=0;
my $help;
my $force;
my $sim_mode=0;

my %options = (
    "h|help" => \$help,
    "n|nice" => \$nice_mode,
    "v|verbose" => \$verbose,
    "f|force" => \$force,
    "c|config-file=s" => \$configfile,
    "s|simulate" => \$sim_mode,
);

my @savedARGV = @ARGV; # Save a copy in case required for rexec
&help unless ( GetOptions(%options));

if ($sim_mode) {
  $verbose = 1;
  print "Simulation mode. Just printing what would be done.\n";
}
&help if ($help);

#############################################################################
### configuration ###########################################################
# Include the library for the config file parser
require 'pkg-cacher-lib.pl';
# Read in the config file and set the necessary variables

# $cfg needs to be global for setup_ownership
our $cfg;

eval {
	 $cfg = read_config($configfile);
};

# not sure what to do if we can't read the config file...
die "Could not read config file: $@" if $@;

define_global_lockfile("$cfg->{cache_dir}/private/exlock");

# check whether we're actually meant to clean the cache
if ( $cfg->{clean_cache} ne 1 ) {
    warn "Maintenance disallowed by configuration item clean_cache\n";
    exit 0;
}
# change uid and gid if root
if ($cfg->{user} && !$> or $cfg->{group} && !$)) {
    printmsg("Invoked as root, changing to $cfg->{user}:$cfg->{group} and re-execing.\n");
    setup_ownership($cfg);
    # Rexec to ensure /proc/self/fd ownerships correct
    exec($0, @savedARGV) or die "Unable to rexec $0: $!\n";
}

# Output data as soon as we print it
$| = 1;

setpriority 0, 0, 20 if $nice_mode;

sub help {
    die <<EOM
    Usage: $0 [ -n ] [ -s|v ] [ -f ] [ -c configfile ]
    -n : nice mode, renice to lowest priority and continue
    -s : simulate mode, just print what would be done to package files
    -v : verbose mode
    -f : force executing, disable sanity checks
EOM
    ;
}

sub printmsg {
   print @_ if $verbose;
}

#
# Two different repository formats are supported: debian/ubuntu and redhat/fedora.
# 		The * portion is treated as repo-root, hashes each containing all the files in one of headers, packages and private are built.
# RedHat
#
# Debian
#
# Do depth first search for empty directories under headers, packages and private then remove them.
#
# Remove all files under cache with link count == 1
#

require Repos::Debian;
require Repos::Fedora;

#############################################################################
# Cache cleaning from here

my $tempdir = "$cfg->{cache_dir}/temp";
mkdir $tempdir if !-d $tempdir;
die "Could not create tempdir $tempdir\n" if !-d $tempdir;
unlink (<$tempdir/*>);

### Preparation of the package lists ########################################

chdir "$cfg->{cache_dir}" && -w "." || die "Could not enter the cache dir";

if ($> == 0 && !$cfg->{user} && !$force) {
    die "Running $0 as root\nand no effective user has been specified. Aborting.\nPlease set the effective user in $configfile\n";
}

my @repos = ();

sub find_wanted {
	my ($list, $pathname) = split('/', $File::Find::name, 2);

	if (-f $_) {
		$files_lists{$list}{$pathname} = 0;
	}

	if ($list eq 'headers') {
		my (undef, $dir) = split('/', $File::Find::dir, 2);

		my $repo;
		
		$repo = Repos::Fedora->checkrepo($_, $dir, $verbose);
		push @repos, ($repo) if defined $repo;
		$repo = Repos::Debian->checkrepo($_, $dir, $verbose);
		push @repos, ($repo) if defined $repo;
	}
}

# file state decisions, lock that area
set_global_lock(": file state decision");

my @find_dirs = ( 'headers', 'private', 'packages' );
find(\&find_wanted, @find_dirs);

delete $files_lists{'private'}{'exlock'};

foreach my $repo (@repos) {
	$repo->process(\%files_lists);
}

foreach my $list (keys %files_lists) {
	foreach my $file (keys %{$files_lists{$list}}) {
		my $filename = $list.'/'.$file;
		print 'Deleting '.$filename."\n" if $verbose;
		unlink $filename if ! $sim_mode;
	}
}

sub cache_wanted {
	my ( undef, undef, undef, $nlinks ) = stat($_);

	if ($nlinks == 1) {
		print 'Deleting unreferenced cache file '.$_."\n" if $verbose;
		unlink $_ if ! $sim_mode;
	}
}

find(\&cache_wanted, ( 'cache' ));

#dump_repos();

#dump_files();

sub dump_files {
	foreach my $list (keys %files_lists) {
		print "list = $list\n";

		foreach my $file (keys $files_lists{$list}) {
			print "file = $file\n";
		}
	}
}

sub dump_repos {
	foreach my $repo (@repos) {
		print 'repo = '.ref($repo).', path = '.$repo->path."\n";
	}
}

unlink (<$tempdir/*>);

release_global_lock();
