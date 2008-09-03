#!/usr/bin/perl

# pkg-cacher-cleanup.pl
# Script to clean the cache for the Pkg-cacher package caching system.
#
# Copyright (C) 2005, Eduard Bloch <blade@debian.org>
# Copyright (C) 2002-03, Jonathan Oxer <jon@debian.org>
# Portions  (C) 2002, Jacob Lundberg <jacob@chaos2.org>
# Distributed under the terms of the GNU Public Licence (GPL).


# do locking, not losing files because someone redownloaded the index files
# right then

use strict;
use warnings;
use lib '/usr/share/pkg-cacher/';

use Cwd;

## Just for testing!
#use File::Basename;
#use lib dirname(Cwd::abs_path $0);

use Fcntl qw/:DEFAULT :flock F_SETFD/;
use Getopt::Long qw(:config no_ignore_case bundling pass_through);
use Digest::SHA1;
use HTTP::Date;

my $configfile = '/etc/pkg-cacher/pkg-cacher.conf';
my $nice_mode=0;
my $verbose=0;
my $help;
my $force;
my $sim_mode=0;
my $offline=0;
my $pdiff_mode=0;
my $db_recover=0;
my @db_mode;
my $patchprog = 'red -s';

my %options = (
    "h|help" => \$help,
    "n|nice" => \$nice_mode,
    "v|verbose" => \$verbose,
    "f|force" => \$force,
    "c|config-file=s" => \$configfile,
    "s|simulate" => \$sim_mode,
    "o|offline" => \$offline,
    "p|pdiff" => \$pdiff_mode,
    "r|recover" => \$db_recover,
    "d|db:s" => \@db_mode
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

my $globlockfile="$cfg->{cache_dir}/private/exlock";
define_global_lockfile($globlockfile);

# check whether we're actually meant to clean the cache
if ( $cfg->{clean_cache} ne 1 ) {
    warn "Maintenance disallowed by configuration item clean_cache\n";
    exit 0;
}
# change uid and gid if root
if ($cfg->{user} && !$> or $cfg->{group} && !$)) {
    printmsg("Invoked as root, changing to $cfg->{user}:$cfg->{group} and re-execing.\n");
    setup_ownership($cfg);
    # Rexec to ensure /proc/self/fd ownerships correct which are needed for red
    # patching with pdiffs
    exec($0, @savedARGV) or die "Unable to rexec $0: $!\n";
}
# Output data as soon as we print it
$| = 1;

setpriority 0, 0, 20 if $nice_mode;

sub help {
    die <<EOM
    Usage: $0 [ -n ] [ -s|v ] [ -o ] [ -f ] [-d command [arg]] [ -c configfile ]
    -n : nice mode, renice to lowest priority and continue
    -s : simulate mode, just print what would be done to package files
    -o : offline mode, don't update index files. Overrides offline_mode from configfile
    -p : patch mode [experimental]. Try to update index files by patching
    -v : verbose mode
    -r : recover, attempt recovery of corrupt checksum database
    -d command [arg]: db mode -- manipulate checksum database.
       Available commands are:
        dump:	      print db contents
	search [arg]: print entries matching regexp
	delete [arg]: delete entries matching regexp
	import:	      read new checksum data from Packages and Sources files in cache_dir
	compact:      clean and compact database
        verify:	      verify the database
    -f : force executing, disable sanity checks
EOM
    ;
}

sub printmsg {
   print @_ if $verbose;
}

sub get {
    my ($file, $use_complete) = @_;
    my $path_info;
    my $fh;
    if($use_complete && -s "../private/$file.complete") {
    # use path is stored in complete file
	open(my $tmp, "../private/$file.complete");
	$path_info=<$tmp>;
	close $tmp;
    }
    else {
	$path_info=$file;
	$path_info=~s/^/\//;
	$path_info=~s/_/\//g;
    }
    open($fh, "| REMOTE_ADDR=CLEANUPREFRESH /usr/share/pkg-cacher/pkg-cacher -i -c $configfile >/dev/null");
    printmsg "GET $path_info\n";
    print $fh "GET $path_info\r\nCache-Control: max-age=0\r\nConnection: Close\r\n\r\n";
    close($fh);
    if($? && ! $force) {
	die "Unable to update $path_info.\nCleanup aborted to prevent deletion of cached data.\n";
    }
}

sub pdiff {
    my $name = $_[0];
    if (!-f $name) {
	warn ("$name not found\n");
	return;
    }

    if ($name !~ /main|contrib|non-free/) {
	printmsg "Upstream repository for $name not recognised layout, skipping attempting to patch\n";
	return;
    }
    my ($basename,$type) = ($name =~ /(^.+?)(\.(?:bz2|gz))?$/);
    (my $release = $basename) =~ s/(?:main|contrib|non-free).*$/Release/;
    (my $diffindex = $basename) .= '.diff_Index';

    for ($release, $diffindex) {
	if (!-f $_ && !$offline) { # Refresh unless offline
	    &get($_);
	}
	if (!-f $_) {
	    printmsg("$_ not available, aborting patch\n");
	    return;
	}
    }

    # Read Release file
    (my $diffindex_patt = $diffindex) =~ s/^.*(main|contrib|non-free.*)/$1/;
    (my $name_patt = $name) =~ s/^.*(main|contrib|non-free.*)/$1/;
    for ($diffindex_patt, $name_patt) {
	s/_/\//g;
    }
#    printmsg "Searching $release for $diffindex_patt and $name_patt\n";
    open(my $rfh, $release) || die "Unable to open $release: $!";
    flock($rfh, LOCK_SH);

    my ($diffindex_sha1, $name_sha1, $name_size);
    while(<$rfh>) {
	if (/^\s(\w{40})\s+\d+\s$diffindex_patt\n/) {
	    $diffindex_sha1 = $1;
#	    printmsg "Found! $diffindex_patt $1\n";
	}
	elsif (/^\s(\w{40})\s+(\d+)\s$name_patt\n/) {
	    $name_sha1 = $1;
	    $name_size = $2;
#	    printmsg "Found! $name_patt $1 $2\n";
	}
	last if ($name_sha1 && $diffindex_sha1);
    }
    flock($rfh, LOCK_UN);
    close($rfh);
    if (!$name_sha1 || !$name_size || !$diffindex_sha1) {
        warn "SHA1s for $name_patt and/or $diffindex_patt not found in $release, aborting patch\n";
	return;
    }

    my $sha1 = Digest::SHA1->new;
    my $digest;

    # Check size first
    if (-s $name == $name_size) {
	printmsg ("$name matches size in $release, going on to check SHA1..\n");
	
	# Check SHA1 only if size correct
	open(my $nfh, $name)|| die "Unable to open file $name for locking: $!";
	flock($nfh, LOCK_SH);	
	$digest = $sha1->addfile(*$nfh)->hexdigest;
	flock($nfh, LOCK_UN);
	close($nfh,);
	if ($digest eq $name_sha1) {
	    printmsg "$name already matches SHA1 in $release: patching not required\n";
	    return 1 # success
	}
	else {
	    printmsg "$name SHA1 not latest: proceeding with patch\n";
	}
    }
    else {
	printmsg ("$name size not latest, proceeding with patch\n");
    }

    # Need to decompress to patch
    my $cat = ($name=~/bz2$/ ? "bzcat" : ($name=~/gz$/ ? "zcat" : "cat"));

    open(my $lck, $name)|| die "Unable to open file $name for locking: $!";
    flock($lck, LOCK_SH);
    open(my $listpipe, "-|", $cat, $name)|| die "Unable to open input pipe for $name: $!";
    open (my $tfh, "+>", undef)|| die "Unable to open temp file: $!";
	
    printmsg "Reading $basename...\n";
    while (<$listpipe>){
	print $tfh $_;
	$sha1->add($_);
    }
    close($listpipe);
    flock($lck, LOCK_UN);
    close($lck,);
    my $rstat =($? >> 8);
    #    printmsg "Read status $rstat\n";
    if ($rstat) {
	warn "$name Read failed, aborting patch\n";
	return;
    }
	
    $digest = $sha1->hexdigest;
#    printmsg "$basename SHA1: $digest\n";

    # Read diff.Index
    my (@hist, @patch);

    open(DIFFIN, $diffindex) || die("Cannot open $diffindex: $!");
    flock(DIFFIN, LOCK_EX);
    my $diffindex_digest = $sha1->addfile(*DIFFIN)->hexdigest;
    if ($diffindex_digest ne $diffindex_sha1) {
	flock(DIFFIN, LOCK_UN);
	close (DIFFIN);
	if ($force) {
	    warn "$diffindex incorrect SHA1: expected $diffindex_sha1, got $diffindex_digest. Continuing anyway as --force specified\n";
	}
	else {
	    warn "$diffindex incorrect SHA1: expected $diffindex_sha1, got $diffindex_digest. Aborting patch. Use --force to ignore\n";
	return;
	}
    }
    seek(DIFFIN,0,0); # rewind
    my $curr= <DIFFIN>; # read first line
    chomp $curr; # remove trailing \n
#    printmsg "$diffindex: $curr\n";
    my ($target_sha1, $target_size) = (split (/\s+/,$curr))[1,2];
    if ($digest eq $target_sha1) { # check this matches /SHA1/
	printmsg "SHA1 match: $name already up to date\n";
	flock(DIFFIN, LOCK_UN);
	close (DIFFIN);
	return 1; # success
    }
    else {
	while (<DIFFIN>) {
	    next if (/^SHA1-History:/); # skip header
	    last if (/^SHA1-Patches:/);# end of history
	    push @hist, $_;
	    next;
	}
	while (<DIFFIN>) {
	    push @patch, $_; # To EOF
	    next;
	}
    }
    flock(DIFFIN, LOCK_UN);
    close (DIFFIN);

    my $diff;
    my $count=0;
    for (@hist) {
	my @line;
	@line = split;
#	printmsg "Checking $digest against @line\n";
	if ( $digest eq $line[0]) {
#	    printmsg "found SHA1 match at \$hist $count: $line[0]\n";
	    $diff = $count;
	    last
	}
	$count++;
    }
    if (!defined $diff) {
	warn "Existing SHA1 not found in diff_Index, aborting patch\n";
	return;
    }

    my $diffs=''; # Initialise to work around perl bug giving "Use of uninitialized value error"
	
    open(DIFFS, ">", \$diffs);
    for (@patch[$diff .. $#patch]) {
	my ($pdiffsha1, $size, $suff) = split;
	my $pdiff = $basename.".diff_".(split)[2].'.gz';
	if (!-f $pdiff) {
	    if (!$offline) {
		&get($pdiff);
	    }
	    if (!-f $pdiff) {
		warn("$pdiff not available, aborting patch");
		return;
	    }
	}
	printmsg "Reading $pdiff\n";
	open(PDIFF, "-|", 'zcat', $pdiff)|| die "Unable to open file $pdiff: $!";
	flock(PDIFF, LOCK_EX);
	while (<PDIFF>) {
	    print DIFFS $_;
	    $sha1->add($_);
	}
	flock(PDIFF, LOCK_UN);
	close(PDIFF);
	$rstat =($? >> 8);
	#	printmsg "Read status $rstat\n";
	if ($rstat) {
	    warn "Read $pdiff failed, aborting patch\n";
	    return;
	}
	my $pdiffdigest = $sha1->hexdigest;
#	printmsg "$pdiff SHA1: $pdiffdigest\n";
	if ($pdiffsha1 ne $pdiffdigest) {
	    warn "$pdiff SHA1 incorrect: got $pdiffdigest, expected $pdiffsha1, aborting patch";
	    return;
	}
    }
    print DIFFS "w\n"; # append ed write command
    close(DIFFS);

    fcntl($tfh, F_SETFD, 0)
      or die "Can't clear close-on-exec flag on temp filehandle: $!\n";
    my $cwd = Cwd::cwd(); # Save
    chdir '/dev/fd' or  die "Unable to change working directory: $!";
    open(my $patchpipe, "| $patchprog ".fileno($tfh)) ||  die "Unable to open pipe for patch: $!";
    printmsg "Patching $name with $patchprog\n";
    print $patchpipe $diffs;
    close($patchpipe);
    chdir $cwd or die "Unable to restore working directory: $!"; # Restore
    $rstat =($? >> 8);
    if ($rstat) {
	warn "Patching failed (exit code $rstat), aborting\n";
	return;
    }
    printmsg "Verifying patched file\n";
    if (-s $tfh != $target_size) {
	warn "$name patching failed! $tfh is not size $target_size\n";
	return;
    }
    seek($tfh,0,0); # rewind
    $sha1->addfile(*$tfh);
    $digest=$sha1->hexdigest;
    if ($digest eq $target_sha1) {
	printmsg "Success! SHA1: $digest\n";
	if ($sim_mode) {
	    printmsg "Simulation mode, so not replacing existing files\n";
	}
	else {
	    my $destfile = "../temp/".$basename.".new".$type;
	    printmsg "Saving as $destfile\n";
	    if (-f $destfile) {
		printmsg "Warning: $destfile already exists\n";
	    }
	    seek($tfh,0,0); # rewind
	    my ($zip,$encoding) = ($name=~/bz2$/ ? ("bzip2","x-bzip2") : ($name=~/gz$/ ? ("gzip -9nc","x-gzip") : "cat"));
	    open(my $writepipe, "| $zip > $destfile") || die "Unable to open output pipe: $!\n";
	    while(<$tfh>) {
		print $writepipe $_;
	    }
	    close($writepipe);
	    my @info = stat($destfile);
	    my $datestring = HTTP::Date::time2str;
	    open(my $hfh, ">", "$destfile.header") || die "Unable to open header file: $!\n";
	    printmsg "Writing header\n";
	    print $hfh <<EOF;
HTTP/1.0 200 OK
Connection: Keep-Alive
Accept-Ranges: bytes
Content-Length: $info[7]
Content-Type: text/plain
Last-Modified: $datestring
EOF
	    if ($encoding) {print $hfh "Content-Encoding: $encoding\n"};
	    close($hfh);
	    # Get global lock and both locks for files
	    set_global_lock(": copy patched file");
	    open(my $pfh, $name)|| die "Unable to open packages/$name for locking: $!";
	    flock($pfh, LOCK_EX);
	    open($hfh, "../headers/$name")|| die "Unable to open headers/$name for locking: $!";
	    flock($hfh, LOCK_EX);
	    printmsg("Linking to $name\n");
	    unlink $name,  "../headers/$name";
	    link $destfile, $name or die "Link $destfile failed: $!";
	    link "$destfile.header", "../headers/$name" || die "Link $destfile.header failed: $!";
	    printmsg "Unlink temporary files\n";
	    unlink $destfile, "$destfile.header";
	    flock($hfh, LOCK_UN);
	    flock($pfh, LOCK_UN);
	    release_global_lock();
	    # Read checksums
	    if ($cfg->{checksum}) {
		printmsg ("Importing new checksums from patched $name\n");
		import_sums($tfh);
	    }
	}
    }
    else {
	warn "$name patching failed! Patched SHA1 is $digest, expecting $target_sha1\n";
	return;
    }
    close $tfh;
    return 1; # success
}

# Calls _db_compact to do the work and reports results
sub db_compact {
    printmsg "Compacting checksum database....\n";
    my ($status, $results) = &_db_compact;
    if ($$status) {
	printmsg "db_compact failed: $$status\n";
    }
    else {
	printmsg " Compacted ". $results->{compact_pages_free} ." pages\n Freed ". $results->{compact_pages_truncated} ." pages\nDone!\n";
    }
}

#############################################################################
# Manipulate checksum database
if (@db_mode || $db_recover){

    my $ok_chars = '-a-zA-Z0-9+_.~'; # Acceptable characters for user input
    print "Checksum database mode\n";

    if (!$cfg->{checksum}) {
	die "checksumming not enabled. Use --force to override\n" if !$force;
	print "checksumming not enabled, but forced to continue\n";
    }
    $verbose = 1; # Just for now

    require 'pkg-cacher-lib-cs.pl';

    if ($db_recover) {
	printmsg "Running database recovery...";
	&db_recover;
	printmsg "Done!\n";
    }

    chdir "$cfg->{cache_dir}/packages" || die "Unable to enter cache dir: $!";

    my $dbref = &db_init("$cfg->{cache_dir}/sums.db")|| die "Unable to init db: $!\n";

  SWITCH:
    for (@db_mode) {
	/^import/ && do {
	    for (<*es.bz2>, <*es.gz>, <*es>, <*Release>, <*diff_Index>) {
		printmsg "Importing checksums from $_\n";
		&import_sums($_) if !$sim_mode;
	    }
	    next SWITCH;
	};
	/^compact/ && do {
	    &db_compact;
	    next SWITCH;
	};
	/^(?:dump|search)/ && do {
	    my $re;
	    if (/^search/){
		$re=shift;
		die "No search expression given\n" if !$re;
		die "Invalid character '$1' in search\n" if $re =~ /([^$ok_chars])/o; # sanitize
	    }
	    while (my ($file,$data) = each %$dbref){
		next if /^search/ && $file !~ /$re/;
		print "$file\n";
		my $href = hashify(\$data);
		while (my ($k,$v) = each %$href) {
		    $v='' if ! defined $v;
		    print " $k: $v\n";
		}
	    }
	    next SWITCH;
	};
	/^delete/ && do {
	    my $re=shift;
	    die "No give regex to match files to delete\n" if !$re;
	    die "Invalid character '$1' in pattern\n" if $re =~ /([^$ok_chars])/o; # sanitize
	    while (my $file = each %$dbref){
		next if $file !~ /$re/;
		printmsg "Deleting data for $file\n";
		delete $dbref->{$file} if !$sim_mode;
	    }
	    next SWITCH;
	};
	/^verify/ && do {
	    printmsg "Waiting for exclusive lock...";
	    if (&db_lock(LOCK_EX)){
		printmsg "Got it!\nVerifying database...";
		printmsg &db_verify("$cfg->{cache_dir}/sums.db", &temp_env) ? "Failed! $!\n" : "Passed!\n";
	    }
	    else {
		warn "Unable to get exclusive database lock: $!\n";
	    }
	    next SWITCH;
	};
	warn "Unknown command $_ ".(shift)."\n";
	next SWITCH;
    }

    exit;
}

#############################################################################

# Cache cleaning from here

# check offline mode in config
if (defined $cfg->{offline_mode} && $cfg->{offline_mode}) {
	$offline = 1;
}

my $dbref;
if ($cfg->{checksum}) {
   require 'pkg-cacher-lib-cs.pl';
   $dbref = &db_init("$cfg->{cache_dir}/sums.db");
}

use DB_File;
tie my %valid, 'DB_File';

my $tempdir="$cfg->{cache_dir}/temp";
mkdir $tempdir if !-d $tempdir;
die "Could not create tempdir $tempdir\n" if !-d $tempdir;
unlink (<$tempdir/*>);

### Preparation of the package lists ########################################

chdir "$cfg->{cache_dir}/packages" && -w "." || die "Could not enter the cache dir";

if($> == 0 && !$cfg->{user} && !$force) {
    die "Running $0 as root\nand no effective user has been specified. Aborting.\nPlease set the effective user in $configfile\n";
}

# file state decisions, lock that area
set_global_lock(": file state decision");
my @ifiles=(<*Release>, <*_Index>, <*es.gz>, <*es.bz2>, <*es>);
release_global_lock();

for my $file (@ifiles) {

   # preserve the index files
   $valid{$file}=1;

   # Try to patch
   my $patched;
   if($pdiff_mode && $file =~ /(?:Packages|Sources)(?:\.(?:bz2|gz))?$/) {
       printmsg "Attempting to update $file by patching\n";
       ($patched = pdiff($file)) || printmsg "Patching failed or not possible\n";
   }
   # If patching failed download them, unless offline
   if (!$patched) {
       if(!$offline) {
	   &get($file);
       }
       else {
	   printmsg "Offline: Reusing existing $file\n";
       }
   }
}

# Ensure corresponding Packages/Sources is present for each diff_Index
DIFFINDEX:
for (@ifiles) {
    if (/^(.+).diff_Index/) {
	printmsg "Checking for $1 for $_\n";
	for ($1,"$1.gz", "$1.bz2") {
	    if ($valid{$_}) {
		printmsg "Found $_\n";
		next DIFFINDEX;
	    }
	}
	printmsg ("Not found. Downloading\n");
	# Might as well use bzipped files
	&get("$1.bz2");
	push @ifiles, "$1.bz2";
	$valid{"$1.bz2"}=1;
    }
}

# use the list of config files we already know
for my $file (@ifiles) {
    printmsg "Reading: $file\n";

    # get both locks and create a temp. copy
    my $tmpfile= "$tempdir/$file";
    set_global_lock(": temporary copy");
    open(my $lck, $file) || do {
	release_global_lock();
	print ("Error: cannot open $file for locking: $!\n");
	next;
    };
    flock($lck, LOCK_EX);
    link($file, $tmpfile) || do {
	release_global_lock();
	print ("Cannot link $file $tmpfile. Check permissions. $cfg->{cache_dir} must be single filesystem.\n");
	next;
    };
    flock($lck, LOCK_UN);
    close($lck);
    release_global_lock();

    if(-e $tmpfile && -z $tmpfile && $tmpfile=~/(?:gz|bz2)$/) {
	# moo, junk, empty file, most likely leftovers from previous versions
	# of pkg-cacher-cleanup where the junk was "protected" from being
	# deleted. Purge later by not having in %valid.
	# delete $valid{$file}; <- will be recreated RSN either way
      die("Found empty index file $file. Delete this manually or use --force if the repository is no longer interesting. \nExiting to prevent deletion of cache contents.\n") unless $force;
      print "Forced ignoring empty index file $file, apparently undownloadable. All packages referenced by it will be lost!\n";
    }
    else {
	extract_sums($tmpfile, \%valid) || die("Error processing $file in $cfg->{cache_dir}/packages, cleanup stopped.\nRemove the file if the repository is no longer interesting and the packages pulled from it are to be removed.\n");
    }
}

printmsg "Found ".scalar (keys %valid)." valid file entries\n";
#print join("\n",keys %valid);

# Remove old checksum data
if ($cfg->{checksum}) {
    my $do_compact;
    $dbref && do {
	  printmsg "Removing expired entries from checksum database\n";
	  while (my $key = each %$dbref){
	      next if defined $valid{$key};
	      printmsg "Deleting checksum data for $key\n";
	      delete $dbref->{$key} if !$sim_mode;
	      $do_compact = 1;
	  }
	  &db_compact if $do_compact || $pdiff_mode;
      };
}

for(<*.deb>, <*.udeb>, <*.bz2>, <*.gz>, <*.dsc>) {
    # should affect source packages but not index files which are added to the
    # valid list above
    if(! defined($valid{$_})) {
	unlink $_, "../headers/$_", "../private/$_.complete" unless $sim_mode;
	printmsg "Removing file: $_ and company...\n";
    }
    else {
	# Verify SHA1 checksum for uncompressed files only
	if(/\.u?deb$/) {
	    my $target_sum = hashify(\$valid{$_})->{sha1};
	    next unless $target_sum;
#	    print "Validating SHA1 $target_sum for $_\n";
	    open(my $fh, $_) || die "Unable to open file $_ to verify checksum: $!";
	    flock($fh, LOCK_EX);
	    if (Digest::SHA1->new->addfile(*$fh)->hexdigest ne $target_sum) {
		unlink $_, "../headers/$_", "../private/$_.complete" unless $sim_mode;
		printmsg "Checksum mismatch: $_, removing\n";
	    }
	    flock($fh, LOCK_UN);
	    close $fh;
	}
    }
}

# similar thing for possibly remaining cruft
chdir "$cfg->{cache_dir}/headers" && -w "." || die "Could not enter the cache dir";

# headers for previously expired files
for(<*.deb>, <*.bz2>, <*.gz>, <*.dsc>) {
   if(! defined($valid{$_})) {
      unlink $_, "../private/$_.complete" unless $sim_mode;
      printmsg "Removing expired headers: $_ and company...\n";
   }
}

# also remove void .complete files, created by broken versions of pkg-cacher in rare conditions
chdir "$cfg->{cache_dir}/private" && -w "." || die "Could not enter the cache dir";
for(<*.deb.complete>, <*.bz2.complete>, <*.gz.complete>, <*.dsc.complete>) {
   s/.complete$//;
   if(! (defined($valid{$_}) && -e "../packages/$_" && -e "../headers/$_") ) {
      printmsg "Removing: $_.complete\n";
      unlink "$_.complete" unless $sim_mode;
   }
}

# last step, kill some zombies

my $now = time();
for(<*.notify>) {
    my @info = stat($_);
    # even the largest package should be downloadable in two days or so
    if(int(($now - $info[9])/3600) > 48) {
	printmsg "Removing orphaned notify file: $_\n";
	unlink $_ unless $sim_mode;
    }
}

#&set_global_lock(": cleanup zombies");

chdir "$cfg->{cache_dir}/packages";

for(<*>) {
    # must be empty and not complete and being downloaded right now
    if(-z $_) {
	my $fromfile;
	if(open($fromfile, $_) && flock($fromfile, LOCK_EX|LOCK_NB)) {
	    # double-check, may have changed while locking
	    if(-z $_) {
		printmsg "Removing zombie files: $_ and company...\n";
		unlink $_, "../headers/$_", "../private/$_.complete" unless $sim_mode;
		flock($fromfile, LOCK_UN);
		close($fromfile);
	    }
	}
    }
}

unlink (<$tempdir/*>);
