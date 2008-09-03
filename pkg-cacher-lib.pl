#! /usr/bin/perl
# This is a library file for Apt-cacher to allow code
# common to Apt-cacher itself plus its supporting scripts
# (apt-cacher-report.pl and apt-cacher-cleanup.pl) to be
# maintained in one location.

# This function reads the given config file into the
# given hash ref. The key and value are separated by
# a '=' and will have all the leading and trailing
# spaces removed.

use strict;
use warnings;
use Fcntl qw/:flock/;
our $cfg;

sub read_config {
    # set the default config variables
    my %config = (
		  cache_dir => '/var/log/cache/apt-cacher',
		  logdir => '/var/log/apt-cacher',
		  admin_email => 'root@localhost',
		  generate_reports => 0,
		  expire_hours => 0,
		  http_proxy => '',
		  use_proxy => 0,
		  http_proxy_auth => '',
		  use_proxy_auth => 0,
		  debug => 0,
		  clean_cache => 0,
		  allowed_hosts_6 => '*',
		  allowed_hosts => '*',
		  limit => 0,
		  daemon_port => 3142,
		  fetch_timeout => 300 # five minutes from now
		 );

    (my $config_file) = @_;

    open CONFIG, $config_file or die $!;

    read(CONFIG, my $buf, 50000);
    $buf=~s/\\\n#/\n#/mg; # fix broken multilines
    $buf=~s/\\\n//mg; # merge multilines

    for(split(/\n/, $buf))
	{
	next if(/^#/); # weed out whole comment lines immediately

	s/#.*//;   # kill off comments
	s/^\s+//;	# kill off leading spaces
	s/\s+$//;	# kill off trailing spaces

		if ($_)
		{
			my ($key, $value) = split(/\s*=\s*/);	# split into key and value pair
			$value = 0 unless ($value);
	    #print "key: $key, value: $value\n";
			$config{$key} = $value;
	    #print "$config{$key}\n";
		}
	}

	close CONFIG;

	return \%config;
}

# check directories exist and are writable
# Needs to run as root as parent directories may not be writable
sub check_install() {
    # Die if we have not been configured correctly
    die "$0: No cache_dir directory!\n" if (!-d $cfg->{cache_dir});

    my $uid = $cfg->{user}=~/^\d+$/ ? $cfg->{user} : getpwnam($cfg->{group});
    my $gid = $cfg->{group}=~/^\d+$/ ? $cfg->{group} : getgrnam($cfg->{group});

    if (!defined ($uid || $gid)) {
	die "Unable to get user:group";
    }

    foreach my $dir ($cfg->{cache_dir}, $cfg->{logdir}, "$cfg->{cache_dir}/private",
		     "$cfg->{cache_dir}/import", "$cfg->{cache_dir}/packages",
		     "$cfg->{cache_dir}/headers", "$cfg->{cache_dir}/temp") {
	if (!-d $dir) {
	    print "Warning: $dir missing. Doing mkdir($dir, 0755)\n";
	    mkdir($dir, 0755) || die "Unable to create $dir";
	    chown ($uid, $gid, $dir) || die "Unable to set ownership for $dir";
	}
    }
    for my $file ("$cfg->{logdir}/access.log", "$cfg->{logdir}/error.log") {
	if(!-e $file) {
	    print "Warning: $file missing. Creating.\n";
	    open(my $tmp, ">$file") || die "Unable to create $file";
	    close($tmp);
	    chown ($uid, $gid, $file) || die "Unable to set ownership for $file";
	}
    }
}

# Convert a human-readable IPv4 address to raw form (4-byte string)
# Returns undef if the address is invalid
sub ipv4_normalise ($) {
	return undef if $_[0] =~ /:/;
	my @in = split (/\./, $_[0]);
	return '' if $#in != 3;
	my $out = '';
	foreach my $num (@in)
	{
		return undef if $num !~ /^[[:digit:]]{1,3}$/o;
		$out .= pack ("C", $num);
	}
	return $out;
}

# Convert a human-readable IPv6 address to raw form (16-byte string)
# Returns undef if the address is invalid
sub ipv6_normalise ($) {
	return "\0" x 16 if $_[0] eq '::';
	return undef if $_[0] =~ /^:[^:]/  || $_[0] =~ /[^:]:$/ || $_[0] =~ /::.*::/;
	my @in = split (/:/, $_[0]);
	return undef if $#in > 7;
	shift @in if $#in >= 1 && $in[0] eq '' && $in[1] eq ''; # handle ::1 etc.
	my $num;
	my $out = '';
	my $tail = '';
	while (defined ($num = shift @in) && $num ne '') # Until '::' found or end
	{
	    # Mapped IPv4
	    if ($num =~ /^(?:[[:digit:]]{1,3}\.){3}[[:digit:]]{1,3}$/) {
		$out .= ipv4_normalise($num);
	    } else {
		return undef if $num !~ /^[[:xdigit:]]{1,4}$/o;
		$out .= pack ("n", hex $num);
	    }
	}
	foreach $num (@in) # After '::'
	{
	    # Mapped IPv4
	    if ($num =~ /^(?:[[:digit:]]{1,3}\.){3}[[:digit:]]{1,3}$/) {
		$tail .= ipv4_normalise($num);
		last;
	    }
	    else {
	        return undef if $num !~ /^[[:xdigit:]]{1,4}$/o;
		$tail .= pack ("n", hex $num);
	    }
	}
	my $l = length ($out.$tail);
	return $out.("\0" x (16 - $l)).$tail if $l < 16;
	return $out.$tail if $l == 16;
	return undef;
}

# Make a netmask from a CIDR network-part length and the IP address length
sub make_mask ($$) {
	my ($mask, $bits) = @_;
	return undef if $mask < 0 || $mask > $bits;
	my $m = ("\xFF" x ($mask / 8));
	$m .= chr ((-1 << (8 - $mask % 8)) & 255) if $mask % 8;
	return $m . ("\0" x ($bits / 8 - length ($m)));
}

# Arg is ref to flattened hash. Returns hash ref
sub hashify {
    unless ($cfg->{debug}){
	no warnings 'uninitialized'
    }
    return {split(/ /, ${$_[0]})};
}

# Stores data flattened for use in tied hashes
sub extract_sums {
   my ($name, $hashref) = @_;
   my ($cat, $listpipe, $indexbase);

   # If arg is filehandle, fileno is undef
   if (fileno $name) {
       seek($name,0,0);
       $listpipe = $name;
   }
   else {
       $cat = ($name=~/bz2$/ ? "bzcat" : ($name=~/gz$/ ? "zcat" : "cat"));

       if($name=~/^(.*_)(?:Index|Release)$/) {
	   $indexbase=$1;
	   $indexbase=~s!.*/!!g;
       }

       open($listpipe, "-|", $cat, $name);
   }
   my ($file,$complete,$sha1,$sha256,$md5,$size);
   while(<$listpipe>) {
       if(/^\s(\w{40})\s+(\d+)\s(\S+)\n/ && $indexbase) { # diff_Index/Release SHA1
	   $sha1=$1;
	   $size =$2;
	   $file=$indexbase.$3;
	   if ($name=~/Release$/) {
	       $file=~s!/!_!g;
	       # MD5 are listed first, so this should already have been set
	       $md5=hashify(\$hashref->{$file})->{md5};
	   }
	   $file.=".gz" if $name=~/Index$/;
	   $complete=1;
       }
       elsif(/^\s(\w{32})\s+(\d+)\s(\S+)\n/ && $indexbase) { # diff_Index/Release MD5
	   $md5=$1;
	   $size=$2;
	   $file=$indexbase.$3;
	   $file=~s!/!_!g if $name=~/Release$/;
	   $file.=".gz" if $name=~/Index$/;
	   $complete=1;
       }
       elsif(/^\s(\w{32})\s+(\d+)\s(\S+)\n/) { # Sources
	   $md5=$1;
	   $size=$2;
	   $file=$3;
	   $complete=1;
       }
       elsif(/^MD5sum:\s+(.*)$/) { # Packages
	   $md5=$1;
       }
       elsif(/^SHA1:\s+(.*)$/) {
	   $sha1=$1;
       }
       elsif(/^SHA256:\s+(.*)$/) {
	   $sha256=$1;
       }
       elsif(/^Size:\s+(.*)$/) {
	   $size=$1;
       }
       elsif(/^Filename:\s+(.*)$/) {
	   $file=$1;
	   $file=~s/.*\///;
       }
       elsif(/^Description:.*$/) {
	   $complete=1;
       }
       if(defined($file) && $complete) {
	   $hashref->{$file}= join ' ', (
					 size => $size || '',
					 md5 => $md5 || '',
					 sha1 => $sha1 || '',
					 sha256 => $sha256 || '',
					 stamp => time()
				      );
	   for ($file, $size, $md5, $sha1, $sha256, $complete) {
	       undef $_
	   }
       }
   };
   return if (fileno $name); # Leave caller to clear up if we were passed a filehandle
   close($listpipe);
   my $ret = ! ($? >> 8);
   return $ret;
}


my $exlock;
my $exlockfile;

sub define_global_lockfile {
    $exlockfile=shift;
}

sub set_global_lock {

    die ("Global lock file unknown") if !defined($exlockfile);

    my $msg=shift;
    $msg='' if !defined($msg);

    debug_message("Entering critical section $msg") if defined (&debug_message);

    #may need to create it if the file got lost
    my $createstr = (-f $exlockfile) ? '' : '>';

    open($exlock, $createstr.$exlockfile);
    if ( !$exlock || !flock($exlock, LOCK_EX)) {
	debug_message("unable to achieve a lock on $exlockfile: $!") if defined (&debug_message);
	die "Unable to achieve lock on $exlockfile: $!";
    }
}

sub release_global_lock {
    debug_message("Exiting critical section") if defined (&debug_message);
    flock($exlock, LOCK_UN);
}

sub setup_ownership {
    my $uid=$cfg->{user};
    my $gid=$cfg->{group};

    if($cfg->{chroot}) {
	if($uid || $gid) {
	    # open them now, before it is too late
	    # FIXME: reopening won't work, but the lose of file handles needs to be
	    # made reproducible first
	    &open_log_files;
	}
	chroot $cfg->{chroot} || die "Unable to chroot, aborting.\n";
	chdir $cfg->{chroot};
    }

    if($gid) {
	if($gid=~/^\d+$/) {
	    my $name=getgrgid($gid);
	    die "Unknown group ID: $gid (exiting)\n" if !$name;
	}
	else {
	    $gid=getgrnam($gid);
	    die "No such group (exiting)\n" if !defined($gid);
	}
	$) = "$gid $gid";
	$( = $gid;
	$) =~ /^$gid\b/ && $( =~ /^$gid\b/ || barf("Unable to change group id");
    }

    if($uid) {
	if($uid=~/^\d+$/) {
	    my $name=getpwuid($uid);
	    die "Unknown user ID: $uid (exiting)\n" if !$name;
	}
	else {
	    $uid=getpwnam($uid);
	    die "No such user (exiting)\n" if !defined($uid);
	}
	$> = $uid;
	$< = $uid;
	$> == $uid && $< == $uid || barf("Unable to change user id");
    }
}

sub barf {
	my $errs = shift;
	die "--- $0: Fatal: $errs\n";
}

my $index_files_regexp =
  '('
  . join('|', ('Index',
	       'Packages.gz',
	       'Packages.bz2',
	       'Release',
	       'Release.gpg',
	       'Sources.gz',
	       'Sources.bz2',
	       'Contents-.+\.gz',
	       'pkglist.*\.bz2',
	       'release$',
	       'release\..*',
	       'srclist.*\.bz2',
	       'Translation-.+\.bz2'
	      )
	)
  . ')$';

sub is_index_file {
    return ($_[0] =~ /$index_files_regexp/);
}

######### HOOKS ###########
#
# arg: file to be scanned and added to DB
sub import_sums {
   return 1;
}

# purpose: ?create?, lock the DB file and establish DB connection
sub db_init {
   return 1;
}

# purpose: create hasher object
sub data_init {
   return 1;
}

# purpose: append data to be scanned
sub data_feed {
   return 1;
}

# args: filename only or filename and sum
sub check_sum {
   return 1;
}

# args: filename and sum
sub store_sum {
}

#### common code for installation scripts ####
sub remove_apache {
    foreach my $apache ("apache", "apache-ssl", "apache2") {
	# Remove the include lines from httpd.conf
	my $httpdconf = "/etc/$apache/httpd.conf";
	if (-f $httpdconf) {
	    my $old = $httpdconf;
	    my $new = "$httpdconf.tmp.$$";
	    my $bak = "$httpdconf.bak";
	    my $done;

	    open(OLD, "< $old")         or die "can't open $old: $!";
	    open(NEW, "> $new")         or die "can't open $new: $!";

	    while (<OLD>) {
		$done += s/# This line has been appended by the Apt\-cacher install script/ /;
		$done += s/Include \/etc\/apt\-cacher\/apache.conf/ /;
		(print NEW $_)          or die "can't write to $new: $!";
	    }

	    close(OLD)                  or die "can't close $old: $!";
	    close(NEW)                  or die "can't close $new: $!";
	
	    if (!$done) {
		unlink $new;
		last;
	    }
	
	    rename($old, $bak)          or die "can't rename $old to $bak: $!";
	    rename($new, $old)          or die "can't rename $new to $old: $!";
#	    if (-f "/etc/init.d/$apache")
#	  {
#	      `/etc/init.d/$apache restart`;
#	  }
	}
    }
}

1;
