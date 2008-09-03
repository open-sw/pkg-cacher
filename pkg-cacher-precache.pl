#!/usr/bin/perl

##
# pkg-cacher-precache.pl
# Script for pre-fetching of package data that may be used by users RSN
#
# Copyright (C) 2005, Eduard Bloch <blade@debian.org>
# Distributed under the terms of the GNU Public Licence (GPLv2).

use Getopt::Long qw(:config no_ignore_case bundling pass_through);
#use File::Basename;
use Cwd 'abs_path';

use strict;

my $distfilter='testing|etch';
my $quiet=0;
my $priofilter='';
#my $expireafter=0;
my $help;
my $noact=0;
my $uselists=0;
my $configfile = '/etc/pkg-cacher/pkg-cacher.conf';

my %options = (
    "h|help" => \$help,
    "d|dist-filter=s"     => \$distfilter,
    "q|quiet"           => \$quiet,
    "p|by-priority=s"     => \$priofilter,
    "n|no-act"          => \$noact,
    "c|cfgfile=s"        => \$configfile,
    "l|list-dir=s"        => \$uselists
);
 

&help unless ( GetOptions(%options));
&help if ($help);

# Include the library for the config file parser
require '/usr/share/pkg-cacher/pkg-cacher-lib.pl';
my $cfgref;
eval {
        $cfgref = read_config($configfile);
};
# not sure what to do if we can't read the config file...
die "Could not read config file: $@" if $@;

$configfile=abs_path($configfile);

# now pick up what we need
my $cachedir=$$cfgref{cache_dir};

sub help {
print "
USAGE: $0 [ options ]
Options:
 -d, --dist-filter=RE  Perl regular experession, applied to the URL of Packages
                       files to select only special versions. Example:
                       'sid|unstable|experimental'
                       (default: 'testing|etch')
 -q, --quiet           suppress verbose output
 -l, --list-dir=DIR    also use pure/compressed files from the specified dir
                       (eg. /var/log/pkg-cacher) to get the package names from.
                       Words before | are ignored (in pkg-cacher logs). To
                       create a such list from clients, see below.
 -p, --by-priority=RE  Perl regular expression for priorities to be looked for
                       when selecting packages. Implies threating all packages
                       with this priority as installation candidates.
                       (default: scanning the cache for candidates without
                       looking at priority)

NOTE: the options may change in the future.
You can feed existing package lists or old pkg-cacher logs into the selection
algorithm by using the -l option above. If the version is omited (eg. for lists
created with \"dpkg --get-selections\" then the packages may be redownloaded).
To avoid this, use following one-liner to fake a list with version infos:

dpkg -l | perl -ne 'if(/^(i.|.i)\\s+(\\S+)\\s+(\\S+)/) { print \"\$2_\$3_i386.deb\\n\$2_\$3_all.deb\\n\"}'

"; exit 1;};

syswrite(STDOUT,
"This is an experimental script. You have been warned.
Run before pkg-cacher-cleanup.pl, otherwise it cannot track old downloads.
") if !$quiet;

my $pcount=0;

chdir "$cachedir/packages" || die "cannot enter $cachedir/packages" ;

my %having; # remember seen packages, just for debugging/noact, emulate what -f would do for us otherwise

sub get() {
   my ($path_info, $filename) = @_;
   if(!defined $having{$filename}) {
      print "I: downloading $path_info\n" if !$quiet;
      $pcount++;
   }

   $having{$filename}=1;

   if(!$noact) {
      open(fh, "| REMOTE_ADDR=PRECACHING /usr/share/pkg-cacher/pkg-cacher -i -c $configfile >/dev/null");
      print fh "GET /$path_info\r\nConnection: Close\r\n\r\n";
      close(fh);
   }
}

my %pkgs;
for (<*>) { 
   s/_.*//g;
   $pkgs{$_}=1;
}

if($uselists) {
   for(<$uselists/*>) {
      my $cat = (/bz2$/ ? "bzcat" : (/gz$/ ? "zcat" : "cat"));
      #open(catlists, "/bin/cat $$cfg{logdir}/access.log $$cfg{logdir}/access.log.1 2>/dev/null ; zcat $$cfg{logdir}/access.log.*.gz 2>/dev/null |");
      if(open(catlists,"-|",$cat,$_)) {
         while(<catlists>){
            chomp;
            s/.*\|//g;
            s/\s.*//g;
            $having{$_}=1; # filter the packages we already have installed
            s/_.*//g;
            $pkgs{$_}=1;
         }
      }
   }
}


PKGITER: for my $pgz (<*Packages*>) {

    # ignore broken files
    next PKGITER if(!-f "../private/$pgz.complete");

   if(length($distfilter)) {
      if($pgz =~ /$distfilter/) {
         print "I: distfilter passed, $pgz\n" if !$quiet;
      }
      else {
         next PKGITER;
      }
   }
   
   my $pgz_path_info=$pgz;
   $pgz_path_info =~ s!_!/!g;
   my $root_path_info = $pgz_path_info;
   $root_path_info =~ s!/dists/.*!!g; # that sucks, pure guessing
   $root_path_info =~ s!/project/experimental/.*!!g; # that sucks, pure guessing

   my ($cat, $listpipe);
   $_=$pgz;
   $cat = (/bz2$/ ? "bzcat" : (/gz$/ ? "zcat" : "cat"));
   
   &get($pgz_path_info, $_);

   print "I: processing $_\n" if !$quiet;
   if(open(pfile,"-|",$cat,$pgz)) {

      my $prio;
      while(<pfile>) {
         chomp;
         if(/^Priority:\s+(.*)/) { $prio=$1; }
         if(s/^Filename:.//) {
            my $deb_path_info="$root_path_info/$_";
            # purify the name
            s!.*/!!g;
            my $filename=$_;
            s!_.*!!g;
            my $pkgname=$_;
            
            if(length($priofilter)) {
               if(!-e $filename && $prio=~/$priofilter/ ) {
                  &get($deb_path_info, $filename);
               }
            }
            elsif($pkgs{$pkgname}) {
               if(!-e $filename) {
                  &get($deb_path_info, $filename);
               }
            }
         }
      }
   }
}

print "Downloaded: $pcount files.\n" if !$quiet;
