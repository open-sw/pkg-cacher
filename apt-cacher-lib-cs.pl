#! /usr/bin/perl

# this are hook methods overload the hooks in apt-cacher-lib.pl and implement
# data checksumming methods

use strict;
use warnings;
no warnings 'redefine';

use BerkeleyDB;
use Digest::MD5;
use Fcntl qw(:DEFAULT :flock);
use Tie::File;

my $ctx;
our ($cfg);
my ($dbh,%db);

sub sig_handler {
    warn "Got SIG@_. Exiting gracefully!\n" if $cfg->{debug};
    exit 1;
}

sub db_init {
    my $dbfile=shift;
    # Need to handle non-catastrophic signals so that END blocks get executed
    for ('INT', 'TERM', 'PIPE', 'QUIT', 'HUP') {
	$SIG{$_} = \&sig_handler unless $SIG{$_};
    }
    my $env;
    my @envargs = (
		   -Home   => $cfg->{cache_dir},
		   -Flags => DB_CREATE | DB_INIT_MPOOL | DB_INIT_CDB
		  );

    my $logfile;
    open($logfile, ">>$cfg->{logdir}/db.log") && push (@envargs, (-ErrFile => $logfile,
								  -ErrPrefix => "[$$]"));
    # Take shared lock
    &db_lock(LOCK_SH)|| die "Shared lock failed: $!\n";
		
    &register_process;
    if (&failchk == DB_RUNRECOVERY) {
	warn "Failed thread detected. Running database recovery\n";
	&db_recover;
    }

    $env = new BerkeleyDB::Env (@envargs);
    if (!$env && db_lock(LOCK_EX|LOCK_NB)) {
	warn "Failed to create DB environment: $BerkeleyDB::Error. Attempting recovery...\n";
	&db_recover;
	$env = new BerkeleyDB::Env (@envargs);
	&db_lock(LOCK_SH)|| die "Shared lock failed: $!\n";
    }
    die "Unable to create DB environment: $BerkeleyDB::Error\n" unless $env;

    # set_timeout returns status, so && not ||
    $env->set_timeout(100,DB_SET_LOCK_TIMEOUT)
      && warn "Unable to set ENV timeout $BerkeleyDB::Error\n";

    $dbh = tie %db, 'BerkeleyDB::Btree',
      -Filename => $dbfile,
	-Flags => DB_CREATE,
	  -Env => $env
	    or die "Unable to open DB file, $dbfile $BerkeleyDB::Error\n";
    return \%db;
}

my $dblock;
sub db_lock {
    if (!$dblock){
	sysopen($dblock, "$cfg->{cache_dir}/private/dblock", O_RDONLY|O_CREAT) ||
	  die "Unable to open lockfile: $!\n";
    }
    return flock($dblock, shift);
}

END {
    &unregister_process;
}

my $register_file="$cfg->{cache_dir}/__db.register";
sub register_process {
    my $h = tie my @processes, 'Tie::File', $register_file or die "$!";
    $h->flock;
    push @processes, $$;
    warn "Registered $$\n" if $cfg->{debug};
}

sub unregister_process {
    unless (-e $register_file) {
	# Any process that loads the library will call this function
	# Pity we can't set the END block only for the right processes
	warn "$$: No $register_file.\n" if $cfg->{debug};
	return;
    }
    my $h = tie my @processes, 'Tie::File', $register_file, mode => O_RDWR or die "$!";
    $h->flock;
    if (grep(/^$$/, @processes)) {
	@processes = grep(!/^$$/, @processes);
	warn "Unregistered $$\n" if $cfg->{debug};
    }
    else {
	%db && warn "Process $$ not registered\n";
    }
}

sub clear_processes {
    my $h = tie my @processes, 'Tie::File', $register_file or die "$!";
    $h->flock;
    @processes = ($$); # Just leave current process
}
sub failchk {
    my $h = tie my @processes, 'Tie::File', $register_file or die "$!";
    $h->flock;
    for (@processes) {
	next unless $_; # Ignore empty lines
	unless (kill 0, $_){ # Check $! ESRCH/EPERM here?
	    warn "Process $_ failed\n";
	    return DB_RUNRECOVERY;
	}
    }
    return 0;
}

sub db_recover {
    &env_remove;
    open(my $logfile, ">>$cfg->{logdir}/db.log");
    my $renv = new BerkeleyDB::Env
      -Home   => $cfg->{cache_dir},
	-ErrFile => $logfile,
	  -Flags  => DB_CREATE | DB_INIT_LOG |
	    DB_INIT_MPOOL | DB_INIT_TXN |
	      DB_RECOVER | DB_PRIVATE | DB_USE_ENVIRON,
		-SetFlags => DB_LOG_INMEMORY
		  or die "Unable to create recovery environment: $BerkeleyDB::Error\n";
    close $logfile;
    &clear_processes;
    return defined $renv;
}

sub env_remove {
    return unlink <$$cfg{cache_dir}/__db.*>; # Remove environment
}

sub temp_env {
    # From db_verify.c
    # Return an unlocked environment
    # First try to attach to an existing MPOOL
    my $tempenv;
    $tempenv = new BerkeleyDB::Env (-Home   => $cfg->{cache_dir},
				    -Flags => DB_INIT_MPOOL | DB_USE_ENVIRON)
      or
	# Else create a private region
	$tempenv = new BerkeleyDB::Env (-Home   => $cfg->{cache_dir},
					-Flags => DB_CREATE | DB_INIT_MPOOL |
					DB_USE_ENVIRON | DB_PRIVATE)
	  or die "Unable to create temporary DB environment: $BerkeleyDB::Error\n";
    return \$tempenv;
}

sub db_verify {
    return BerkeleyDB::db_verify (-Filename=>shift, -Env=>$+{shift});
}


# Returns reference to status and hash of compaction data
sub _db_compact {
    my %hash;
    my $status;
    return (\'DB not initialised in _db_compact', undef) unless $dbh;
  SWITCH:
    for ($dbh->type) {
	/1/ && do { # Btree
	    $status = $dbh->compact(undef,undef,\%hash,DB_FREE_SPACE);
	    last SWITCH;
	};
	/2/ && do { # Hash
	    $status = $dbh->compact(undef,undef,\%hash,DB_FREELIST_ONLY);
	    last SWITCH;
	};
    }
    return (\$status,\%hash);
}

# arg: file or filehandle to be scanned and added to DB
sub import_sums {
    return unless $cfg->{checksum};
    my $lock = $dbh->cds_lock();
    extract_sums(shift, \%db);
    # Unnecessary. Happens automatically when out of scope
    # $lock->cds_unlock();

}

# purpose: create hasher object
sub data_init {
    return 1 unless $cfg->{checksum};
    $ctx = Digest::MD5->new;
    return 1;
}

# purpose: append data to be scanned
sub data_feed {
    return unless $cfg->{checksum};
    my $ref=shift;
    $ctx->add($$ref);
}

# arg: filename
sub check_sum {
    return 1 unless $cfg->{checksum};
    my $file = shift;
    my $digest = $ctx->hexdigest;
    my $href = hashify(\$db{$file}) if $db{$file};
    if($href->{md5} && length($href->{md5}) == 32) {
	# now find the faulty deb
	debug_message("Verify $file: db $href->{md5}, file $digest");
	return ($href->{md5} eq $digest);
    }
    debug_message("No stored md5sum found for $file. Ignoring");
    return 1;
}

1;
