#!/usr/bin/perl
#	apt-cacher.pl - CGI to provide a local cache for debian packages and release files and .deb files
#
#  $Revision: 1.11 $
#  $Source: /xenu/nick/CVS-TREE/Src/Apt-cacher/apt-cacher.pl,v $
#  $Date: 2002/01/24 23:11:12 $
#
#  Usage: run from apache, which provides this environment variable:
#	PATH_INFO=/www.domain.name/some/path/filename

=head1 NAME

 apt-cacher.pl - CGI to provide a cache for downloaded Debian packages

 Copyright (C) 2001 Nick Andrew <nick@zeta.org.au>
 Copyright (C) 2002-2004 Jonathan Oxer <jon@debian.org>
 Copyright (C) 2002 Raphael Goulais <raphael@nicedays.net>
 Copyright (C) 2002 Jacob Luna Lundberg <jacob@chaos2.org>
 Copyright (C) 2003 Daniel Stone <dstone@kde.org>
 Copyright (C) 2003 Adam Moore <adam@ihug.co.nz>
 Copyright (C) 2003 Andreas Boeckler <abo@netlands.de>
 Copyright (C) 2003 Stephan Niemz <st.n@gmx.net>
 Copyright (C) 2005 Darren Salt <linux@youmustbejoking.demon.co.uk>
 Copyright (C) 2005 Eduard Bloch <blade@debian.org>
 Distributed under the terms of the GNU Public Licence (GPL).

=head1 SYNOPSIS

 copy apt-cacher.pl to your apache cgi-bin directory
 ./setup.pl /home/me/cache
 edit /etc/apt/sources.list
 apt-get update
 apt-get -u upgrade

=head1 DESCRIPTION

If you have two or more Debian GNU/Linux machines on a fast local
network and you wish to upgrade packages from the Internet, you
don't want to download every package several times.

apt-cacher.pl is a CGI which will keep a cache on disk of Debian Packages
and Release files (including .deb files) which have been received from Debian
distribution servers on the Internet. When an apt-get client issues
a request for a file to apt-cacher.pl, if the file is already on disk
it is served to the client immediately, otherwise it is fetched from
the Internet, saved on disk, and then served to the client. This means
that several Debian machines can be upgraded but each package need be
downloaded only once.

To use this CGI you need a web server which supports CGI and a local
directory with plenty of free space (100 Mbytes or more, depends on the
requirements of the cache using client systems).

=head1 INSTALLATION

Assuming your web server is called B<www.myserver.com:80>
and your cache directory is called B</home/me/cache>, then:

1. Copy apt-cacher.pl to your web server's cgi-bin directory

2. Make sure apt-cacher.pl is executable (chmod a+rx apt-cacher.pl)

3. Edit apt-cacher.pl and set $cache_dir to /home/me/cache

4. Make sure apt-cacher.pl is ok to run (B<perl -Mstrict -wc apt-cacher.pl>)

5. Run B<./setup.pl /home/me/cache> to create necessary directories

6. Make sure your client machines can access http://www.myserver.com:80/cgi-bin/apt-cacher.pl

If the CGI is executed without arguments, it will return a text/plain
error message.

7. Edit your /etc/apt/sources.list files, as follows. Where a line says
something like:

deb http://http.us.debian.org/debian testing main contrib non-free

change this to:

deb http://www.myserver.com:80/cgi-bin/apt-cacher.pl/http.us.debian.org/debian testing main contrib non-free

8. Do "apt-get update" as root. This will prime the cache directory with the
Package or Package.gz and Release files from the servers you used to use
directly.

9. Do "ls -laR /home/me/cache" to verify that files have been received and
stored. The "/home/me/cache/tmp" directory should be empty after downloads
have completed.

10. Do "apt-get update; apt-get -u upgrade" to start upgrading each machine.

=head1 CACHE DIRECTORY CONTENTS

apt-cacher.pl considers all .deb files with exactly the same filename
should be the same package (for example vim-rt_5.8.007-4_all.deb) no
matter where they are downloaded from, so these files are stored in
the cache directory using just the filename.

Packages and Release files (including Packages.gz) are potentially
different for every server and directory, so these files are stored
in the cache directory with the full hostname and path to the file,
with all slashes B</> changed to underscores B<_> (in the same
manner as apt-get names the files in B</var/lib/apt/lists>).

=head1 BUGS and FEATURES

1. Only HTTP is supported at present (i.e. apt-cacher.pl cannot access an
FTP URL)

2. apt-cacher.pl probably only works with the Apache webserver, because
it relies on the webserver supplying the PATH_INFO environment variable. There
is alternative method with standard compliant CGI environment but it needs more
testing, and it needs additonal config on the client side to work around APT's
bugs.

3. apt-cacher.pl uses B<curl> to retrieve files, so wget must be
installed.

4. (this bug has been squashed)

5. (this bug has been squashed)

6. (this bug has been squashed)

7. (this bug has been squashed)

8. apt-get can resume a partial failed transfer, however apt-cacher.pl
cannot.

9. (fixed)

10. (fixed)

11. (fixed)

12. (this bug has been squashed)

=head1 ENVIRONMENT VARIABLES

B<PATH_INFO> is used to find the full URL for the requested file

B<QUERY_STRING> fallback path to get host/url from, for non-apache http daemons

=head1 UPDATES

Please email bug fixes and enhancements using Debian's bug tracking system, http://bugs.debian.org/.

=cut
# ----------------------------------------------------------------------------
# use strict;
use warnings;
# Set the version number (displayed on the info page)
$version='0.8.6';
$|=1;

my $path = $ENV{PATH_INFO};

my $addq='';
if(!$path) {
   $path = $ENV{QUERY_STRING};
   $addq = '?';
}


my @index_files = (
	'Packages.gz',
	'Packages.bz2',
	'Release',
	'Release.gpg',
	'Sources.gz',
	'Sources.bz2',
	'Contents-.+\.gz',
);
my $index_files_regexp = '(' . join('|', @index_files) . ')$';


# Include the library for the config file parser
require '/usr/share/apt-cacher/apt-cacher-lib.pl';
require '/etc/apt-cacher/checksumming.conf';

# Read in the config file and set the necessary variables
my $configfile = '/etc/apt-cacher/apt-cacher.conf';

my $configref;
eval {
        $configref = read_config($configfile);
};
my %config = %$configref;

# not sure what to do if we can't read the config file...
die "Could not read config file: $@" if $@;

# Now set some things from the config file
# $logfile used to be set in the config file: now we derive it from $logdir
$config{logfile} = "$config{logdir}/access.log";

# $errorfile used to be set in the config file: now we derive it from $logdir
$config{errorfile} = "$config{logdir}/error.log";

# don't block access unless explicitely requrested. This was the old default behaviour.
$config{allowed_hosts_6} = '*' if !defined($config{allowed_hosts_6});
$config{allowed_hosts} = '*' if !defined($config{allowed_hosts});

my $private_dir = "$config{cache_dir}/private";
my $exlockfile = "$private_dir/exlock";
my $exlock;

#my $do_lock = 0;

# use IO::Handle;
use Fcntl ':flock';
use IO::Handle;
use POSIX;

#optional checksumming support
db_init("$config{cache_dir}/md5sums.sl3");

# Output data as soon as we print it
$| = 1;

# Function prototypes
sub ipv4_addr_in_list ($$);
sub ipv6_addr_in_list ($$);
sub get_abort_time ();

# ----------------------------------------------------------------------------
# Die if we have not been configured correctly
die "apt-cacher.pl: No cache_dir directory!\n" if (!-d $config{cache_dir});
die "apt-cacher.pl: No cache_dir/tmp directory!\n" if (!-d "$config{cache_dir}/tmp");
die "apt-cacher.pl: No cache_dir/private directory!\n" if (!-d $private_dir);

# ----------------------------------------------------------------------------
# Let's do some security checking. We only want to respond to clients within an
# authorised address range (127.0.0.1 and ::1 are always allowed).

my $ip_pass = 1;
my $ip_fail = 0;
my $client = $ENV{REMOTE_ADDR};
my $clientaddr;

# allowed_hosts == '*' means allow all ('' means deny all)
# denied_hosts == '' means don't explicitly deny any
# localhost is always accepted
# otherwise host must be in allowed list and not in denied list to be accepted

if ($client =~ /:/) # IPv6?
{
   defined ($clientaddr = ipv6_normalise ($client)) or goto badaddr;
   if (substr ($clientaddr, 0, 12) eq "\0\0\0\0\0\0\0\0\0\0\xFF\xFF")
   {
      $clientaddr = substr ($clientaddr, 12);
      goto is_ipv4;
   }
   elsif ($clientaddr eq "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\1")
   {
      debug_message("client is localhost");
   }
   else
   {
      $ip_pass = ($config{allowed_hosts_6} =~ /^\*?$/) ||
      ipv6_addr_in_list ($clientaddr, 'allowed_hosts_6');
      $ip_fail = ipv6_addr_in_list ($clientaddr, 'denied_hosts_6');
   }
}
elsif (defined ($clientaddr = ipv4_normalise ($client))) # IPv4?
{
   is_ipv4:
   if ($clientaddr eq "\x7F\0\0\1")
   {
      debug_message("client is localhost");
   }
   else
   {
      $ip_pass = ($config{allowed_hosts} =~ /^\*?$/) ||
      ipv4_addr_in_list ($clientaddr, 'allowed_hosts');
      $ip_fail = ipv4_addr_in_list ($clientaddr, 'denied_hosts');
   }
}
else
{
   goto badaddr;
}

# Now check if the client address falls within this range
if ($ip_pass && !$ip_fail)
{
	# Everything's cool, client is in allowed range
	debug_message("Client $client passed access control rules");
}
elsif($client eq "local")
{
	# Everything's cool, client is in allowed range
	debug_message("Client $client passed access control rules");
}
else
{
	# Bzzzt, client is outside allowed range. Send 'em a 403 and bail.
	badaddr:
	debug_message("Alert: client $client disallowed by access control");
	write_to_server("Status: 403 Access to cache prohibited\n\n");
	exit(4);
}

# ----------------------------------------------------------------------------
# Data also used by child processes

my $unique_filename;
my $child_pid;
my $child_completed;
my $child_rc;

# ----------------------------------------------------------------------------

# $SIG{'PIPE'} = sub { open(E, ">>$cache_dir/errs"); print E "$$ received SIGPIPE\n"; close(E); };
# $SIG{'PIPE'} = 'IGNORE';
my $sigpipe_received = 0;

$SIG{'PIPE'} = sub {
	#print STDERR "--- apt-cacher.pl: received SIGPIPE\n";
	debug_message("received SIGPIPE");
	$sigpipe_received = 1;
};

sub term_handler {
	#print STDERR "--- apt-cacher.pl: received SIGTERM, terminating\n";
	debug_message("received SIGTERM, terminating");
	
	# Kill the wget process if running and unlink its output file

	kill('TERM', $child_pid) if ($child_pid);
	unlink($unique_filename) if ($unique_filename);
	exit(8);
};

$SIG{'TERM'} = \&term_handler;

$SIG{'QUIT'} = sub { writeerrorlog("received SIGQUIT"); };
$SIG{'INT'}  = sub { writeerrorlog("received SIGINT");  };

#print STDERR "\n--- apt-cacher.pl: called with $path\n";
debug_message("called with $path");

#$debug = 1 if (-f "$cache_dir/debug");

`touch $exlockfile` if ! -f $exlockfile;

# Now parse the path
if ($path =~ /^\/?report/) {
       usage_report();
       exit(0);
}

if ($path !~ m(^/?.+/.+)) {
	usage_error();
	exit(4);
}


my($host,$uri) = ($path =~ m(^/?([^/]+)(/.+)));

if ($host eq '' || $uri eq '') {
	usage_error();
	exit(4);
}

my ($filename) = ($uri =~ /\/?([^\/]+)$/);
my $new_filename;

my $is_open = 0;	# Is the file currently open by us?

if(defined($config{allowed_locations})) {
   #         debug_message("Doing location check for ".$config{allowed_locations} );
   my $mess;
   my $cleanuri=$uri;
   $cleanuri=~s!/[^/]+/[\.]{2}/!/!g;
   if ($host eq ".." ) {
      $mess = "'..' contained in the hostname";
   }
   elsif ($cleanuri =~/\/\.\./) {
      $mess = "File outside of the allowed path";
   }
   else {
      for(split(/,/,$config{allowed_locations})) {
         debug_message("Testing URI: $host$cleanuri on $_");
         goto location_allowed if ("$host$cleanuri" =~ /^$_/);
      }
      $mess = "Host '$host' is not configured in the allowed_locations directive";
   }
   badguy:
   debug_message("$mess; access denied");
   write_to_server("Status: 403 Forbidden.\n\n$mess.\n\n");
   exit(4);
}
location_allowed:

my $do_import=0;

if ($filename =~ /(\.deb|\.rpm|\.dsc|\.tar\.gz|\.diff\.gz|\.udeb)$/) {
	# We must be fetching a .deb or a .rpm, so let's cache it.
	# Place the file in the cache with just its basename
	$new_filename = $filename;
	debug_message("new filename with just basename: $new_filename");
} elsif ($filename =~ /$index_files_regexp/) {
	# It's a Packages.gz or related file: make a long filename so we can cache these files without
	# the names colliding
	$new_filename = "$host$uri";
	$new_filename =~ s/\//_/g;
  debug_message("new long filename: $new_filename");
  # optional checksumming support
  if ($filename =~ /(Packages|Sources)/) {
     # warning, an attacker could poison the checksum cache easily
     $do_import=1;
  }
} else {
	# Maybe someone's trying to use us as a general purpose proxy / relay.
	# Let's stomp on that now.
	debug_message("Sorry, not allowed to fetch that type of file: $filename");
	write_to_server("Status: 403 Forbidden. Not allowed to fetch that type of file\n\n");
	exit(4);
}

my $cached_file = "$config{cache_dir}/packages/$new_filename";
my $cached_head = "$config{cache_dir}/headers/$new_filename";
my $errflagfile = "$cached_head.error";

debug_message("looking for $cached_file");

if ($filename =~ /$index_files_regexp/) {
	debug_message("known as index file: $filename");
#  setlock; global lock used here sucks, to deep impact on performance for possible (low) risk scenarios
	if (-f _) {
     if($config{expire_hours} > 0) {
        my $now = time();
        my @stat = stat($cached_file);
        if (@stat && int(($now - $stat[9])/3600) > $config{expire_hours}) {
           #print STDERR "--- Unlinking $new_filename because it is too old\n";
           debug_message("unlinking $new_filename because it is too old");
           # Set the status to EXPIRED so the log file can show it was downloaded again
           $cache_status = "EXPIRED";
           debug_message("$cache_status");
           unlink $cached_file, $cached_head, "$private_dir/$new_filename.complete";
        }
     }
     else {
        # use HTTP timestamping
        my ($oldhead, $testfile, $newhead);
        open(my $fhead, "-|", "/usr/bin/curl", "-I", "http://$host$uri", '-D-', '--stderr', "/dev/null");
        while(<$fhead>) {
           $newhead = $1 if /.*Last-Modified:([^\n\r]+).*/;
        }
        close($fhead);
        if(open($testfile, $cached_head)) {
           for(<$testfile>){
              if(/^.*Last-Modified:(.*)(\r|\n)/) {
                 $oldhead = $1;
                 last
              }
           }
           close($testfile);
        }
        if($oldhead && $newhead && ($oldhead eq $newhead) ) {
           # that's ok
           debug_message("remote file not changed, $oldhead vs. $newhead");
        }
        else {
           #print STDERR "--- Unlinking $new_filename because it is too old\n";
           debug_message("unlinking $new_filename because it differs from server's version");
           $cache_status = "EXPIRED";
           debug_message("$cache_status");
           unlink $cached_file, $cached_head, "$private_dir/$new_filename.complete";
        }
     }
  }
#  unlock;
}

&setlock; # file state decissions, lock that area

if (!-f $cached_file) {
	# File does not exist or is a broken symlink, so try to create it
	unlink($cached_file, "$private_dir/$new_filename.complete");
	debug_message("file does not exist, creating it");
	# Set the status to MISS so the log file can show it had to be downloaded
	$cache_status = "MISS";
	debug_message("$cache_status");
	if (sysopen(CF, $cached_file, O_RDWR|O_CREAT|O_EXCL, 0644)) {
		$is_open = 1;
	}
} else {
	# Set the status to HIT so the log file can show it came from cache
	$cache_status = "HIT";
	debug_message("$cache_status");
}



if (!-f $cached_file) {
	barf("Tried to create $cached_file, but failed");
}

# Is it incomplete?
if (!-f "$private_dir/$new_filename.complete") {
   debug_message("file is not complete");
   $cache_status = "MISS";

   if (!$is_open) {
      debug_message("open $cached_file");
      if (!sysopen(CF, $cached_file, O_RDWR)) {
         writeerrorlog("unable to open incomplete $cached_file: $!");
         barf("Unable to open incomplete $cached_file: $!");
      }
   }

   if (flock(CF, LOCK_EX|LOCK_NB)) {
      # file locked, nobody's touching it ...
      # Have to truncate it, because we can't rely on "resume"
      truncate(CF, 0);
      # we can fetch, remove the error file
      unlink $errflagfile;
      &try_pickup;
   }
}

&unlock;

# At this point the file is open, and it's either complete or somebody
# is fetching its contents


#print STDERR "--- Starting to return $cached_file\n";
debug_message("starting to return $cached_file");

my $first_line = 1;
my($buf,$n);
my $header_printed=0;

$fetch_timeout=300; # five minutes from now

# reopen the file to not share the lock with the fetcher
my $fromfile;
if (!sysopen($fromfile, $cached_file, O_RDONLY)) {
   # don't barf. If there are network problems, they are signaled via errorfile
   # below, but not here
#   writeerrorlog("weird, unable to open incomplete $cached_file: $!");
#   barf("weird, Unable to open incomplete $cached_file: $!");
}

data_init();
my $abort_time = get_abort_time();

while (1) {
	if ($sigpipe_received) {
		#print STDERR "--- Exit (SIGPIPE)\n";
		debug_message("exit (SIGPIPE)");
		exit(4);
	}
	
  my $n=0;
  my $buf;
  my @statinfo=stat($cached_head);
  
  # 100 should be enough as flag, since
  # hopefully the headers files are always small enough to be written to the
  # disk atomicaly
  if(@statinfo && $statinfo[7]>100) {      
     $n = sysread($fromfile, $buf, 65536);
     barf("Oops, read failed!") if (!defined $n);
  }
  else {
     debug_message("no header yet...\n");
  }

	debug_message("read $n bytes");

	if ($n < 0) {
		#print STDERR "--- Exit (read fail)\n";
		debug_message("exit (read failed)");
		exit(4);
	}

  my $code;
  if (-f $errflagfile) {
     open(my $in, $errflagfile); $code=<$in>;
     debug_message("exit (file failed, $code)");
     if(!$header_printed) { # don't return crap, status as data
        write_to_server("Status: $code Error trying to fetch the file\n\n");
     }
     writeaccesslog("MISS", "$new_filename");
     exit(0);
  }

  if(!$header_printed && $n>0) {
     $header_printed=1;
     # prepend the header in the first chunk
     my $head;
     if($cached_head && open(my $in, $cached_head)) {
        <$in>; # drop the status and date lines
        $head=join("", <$in>);
     }
     if(!$head) {
        debug_message("Header squashed!");
        write_to_server("Status: 502 Error trying to fetch the file\n\n");
        unlink $cached_file; #FIXME
        exit 0;
     }
     write_to_server($head);
  }

  if ($n == 0) {
     # if the fetcher is done, we can lock/unlock it
     if (flock($fromfile, LOCK_EX|LOCK_NB)) {
        flock($fromfile, LOCK_UN);
        # Looks like file is complete!
        # Finish up
        #print STDERR "--- Exit (file completed)\n";
        debug_message("exit (file completed)");

        last;
     }

     if (time() > $abort_time) {
        #print STDERR "--- Abort (timeout)\n";
        debug_message("abort (timeout)");
        exit(4);
     }
     sleep(2); # *don't* rely on this not being interrupted!
     next;
  }

  $abort_time = get_abort_time();

		write_to_server($buf);
    data_feed(\$buf);
		#print STDERR "Wrote ", length($buf), " bytes\n" if ($debug);
		debug_message("wrote " . length($buf) . " bytes");
}

# Write all the stuff to the log file
writeaccesslog("$cache_status", "$new_filename");
if(!check_sum($new_filename)) {
   debug_message("ALARM! Faulty package in local cache detected! Replacing: $new_filename");
   unlink $cached_file;
   exit(4);
}
# We're done!
exit(0);

#####################################################################
# End of the main program
#####################################################################

sub barf {
	my $errs = shift;

	die "--- apt-cacher.pl: Fatal: $errs\n";
}

sub usage_error {
	print STDERR "--- apt-cacher.pl: Usage error\n";

	print <<EOF;
Content-Type: text/html
Expires: 0

<html>
<title>Apt-cacher version $version
</title><style type="text/css"><!--
a { text-decoration: none; }
a:hover { text-decoration: underline; }
h1 { font-family: arial, helvetica, sans-serif; font-size: 18pt; font-weight: bold;}
h2 { font-family: arial, helvetica, sans-serif; font-size: 14pt; font-weight: bold;}
body, td { font-family: arial, helvetica, sans-serif; font-size: 10pt; }
th { font-family: arial, helvetica, sans-serif; font-size: 11pt; font-weight: bold; }
//--></style>
</head>
<body>
<p>
<table border=0 cellpadding=8 cellspacing=1 bgcolor="#000000" align="center" width="600">
<tr bgcolor="#9999cc"><td> <h1>Apt-cacher version $version</h1> </td></tr>
<tr bgcolor="#cccccc"><td>
Usage: edit your /etc/apt/sources.list so all your HTTP sources are prepended 
with the address of your apt-cacher machine and 'apt-cacher', like this:
<blockquote>deb&nbsp;http://ftp.au.debian.org/debian&nbsp;unstable&nbsp;main&nbsp;contrib&nbsp;non-free</blockquote>
becomes
<blockquote>deb&nbsp;http://<b>yourcache.example.com/apt-cacher$addq/</b>ftp.au.debian.org/debian&nbsp;unstable&nbsp;main&nbsp;contrib&nbsp;non-free</blockquote>
</td></tr>
</table>

<h2 align="center">config values</h2>
<table border=0 cellpadding=3 cellspacing=1 bgcolor="#000000" align="center">
<tr bgcolor="#9999cc"><th> Directive </th><th> Value </th></tr>
<tr bgcolor="#cccccc"><td bgcolor="#ccccff"> configfile </td><td> $configfile </td></tr>
<tr bgcolor="#cccccc"><td bgcolor="#ccccff"> admin_email </td><td> <a href="mailto:$config{admin_email}">$config{admin_email}</a> </td></tr>
<tr bgcolor="#cccccc"><td bgcolor="#ccccff"> generate_reports </td><td> $config{generate_reports} </td></tr>
<tr bgcolor="#cccccc"><td bgcolor="#ccccff"> cache_dir </td><td> $config{cache_dir} </td></tr>
<tr bgcolor="#cccccc"><td bgcolor="#ccccff"> logfile </td><td> $config{logfile} </td></tr>
<tr bgcolor="#cccccc"><td bgcolor="#ccccff"> errorfile </td><td> $config{errorfile} </td></tr>
<tr bgcolor="#cccccc"><td bgcolor="#ccccff"> expire_hours </td><td> $config{expire_hours} </td></tr>
<tr bgcolor="#cccccc"><td bgcolor="#ccccff"> http_proxy </td><td> $config{http_proxy} </td></tr>
<tr bgcolor="#cccccc"><td bgcolor="#ccccff"> use_proxy </td><td> $config{use_proxy} </td></tr>
<tr bgcolor="#cccccc"><td bgcolor="#ccccff"> use_proxy_auth </td><td> $config{use_proxy_auth} </td></tr>
<tr bgcolor="#cccccc"><td bgcolor="#ccccff"> debug </td><td> $config{debug} </td></tr>
</table>

<p>
<h2 align="center">license</h2>
<table border=0 cellpadding=8 cellspacing=1 bgcolor="#000000" align="center" width="600">
<tr bgcolor="#cccccc"><td>
<p>Apt-cacher is free software; you can redistribute it and/or modify it under the terms of the GNU General 
Public License as published by the Free Software Foundation; either version 2 of the License, or (at your 
option) any later version.

<p>Apt-cacher is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the 
implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public 
License for more details.

<p>A copy of the GNU General Public License is available as /usr/share/common-licenses/GPL in the Debian 
GNU/Linux distribution or on the World Wide Web at http://www.gnu.org/copyleft/gpl.html. You can also 
obtain it by writing to the Free Software Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 
02111-1307, USA.
</td></tr>
</table>
</body>
</html>
EOF

}

sub try_pickup {

	my $pid = fork();
	if ($pid < 0) {
		barf("fork() failed");
	}

	if ($pid > 0) {
		# parent
		return;
	}

	# child

	my $url = "http://$host$uri";

  # using curl, but separating the header manually to make sure that it is
  # stored on disk before the data is stored
  #
  debug_message("fetcher: try to pick up $url");
  @elist=("/usr/bin/curl", '-D-', 
  '--stderr', "/dev/null",
  $url);

  # for checksumming
  data_init();

  # Check whether a proxy is to be used, and set the appropriate environment variable
  if ( $config{use_proxy} eq 1 && $config{http_proxy}) {
     push(@elist, "-x", "http://$config{http_proxy}");
  }
  # Check whether proxy authentication is to be used, and set the appropriate environment variable
  if ( $config{use_proxy_auth} eq 1 && $config{http_proxy_auth}) {
     push(@elist, "-U", "$config{http_proxy_auth}");
  }
  # Check if we need to set a rate limiting value: otherwise make it null
  push(@elist,"--limit-rate", $config{limit}) if ($config{limit} > 0);
  debug_message("Executing @elist"); 
  # Run the command we've built up
  my ($data, $getpipe, $chfd);
  open($chfd, ">$cached_head");
  open($getpipe, "-|", @elist);
  while(<$getpipe>) {
     if($data) { 
        data_feed(\$_) if !$do_import; # checksum passed data if not an meta file
        print CF $_;
        next ; 
     }
     s/\r//;
     print $chfd $_;
     if(/^$/) {
        close($chfd);
        $data=1;
     }
  }
  close($getpipe);
  my $rc=($?>>8);

	#print STDERR "--- Pick up $url as $cached_file, return code $rc\n";
	debug_message("pick up $url as $cached_file, return code $rc");

  # check missmatch or fetcher failure, could not connect the server
  if(!check_sum($new_filename)) {
     debug_message("Do00h, checksum mismatch on $new_filename");
     $rc=123;
  }
  if ($rc != 0) {
     unlink $cached_file, $cached_head;
     open(MF, ">$errflagfile");
     print MF 502;
     close(MF);
     exit(0);
  }

  open($tmp, $cached_head);
  my $code = <$tmp>;
  $code =~ s/HTTP\S+\s(\d+).*/$1/s;
  close($tmp);
  
  if($code =~ /^[45]/) {
     open(MF, ">$errflagfile");
     print MF $code;
     close(MF);
     unlink $cached_file, $cached_head;
     exit(0);
  }

	# Touch the new file to fix the timestamp (this fixes the bug that was previously
	# causing apt-cacher to re-download files that it thought had expired, but which
	# were actually new: thanks Raphael!)
	my $now = time;
	utime $now, $now, $cached_file;

	# Now create the file to show the pickup is complete, also store the original URL there
	open(MF, ">$private_dir/$new_filename.complete");
  print MF $path;
	close(MF); 
  ## FIXME ##  this assumes that the filesystem does nott s**t us and will make
  ## the file visible to other processes as soon as it this close command returns

  flock(CF, LOCK_UN); # release it, notifying the readers

  import_sums($cached_file) if $do_import;
		
	#print STDERR "--- Fetcher exiting\n";
	debug_message("fetcher exiting");

	exit(0);
}


# Check if there has been a usage report generated and display it
sub usage_report{
	$usage_file = "$config{logdir}/report.html";
	if (!-f $usage_file) {
		print <<EOF;
Content-Type: text/html

<html>
<title>Apt-cacher traffic report</title><style type="text/css"><!--
a { text-decoration: none; }
a:hover { text-decoration: underline; }
h1 { font-family: arial, helvetica, sans-serif; font-size: 18pt; font-weight: bold;}
h2 { font-family: arial, helvetica, sans-serif; font-size: 14pt; font-weight: bold;}
body, td { font-family: arial, helvetica, sans-serif; font-size: 10pt; }
th { font-family: arial, helvetica, sans-serif; font-size: 11pt; font-weight: bold; }
//--></style>
</head>
<body>
<table border=0 cellpadding=8 cellspacing=1 bgcolor="#000000" align="center" width="600">
<tr bgcolor="#9999cc"><td> <h1>Apt-cacher traffic report</h1> </td></tr>
</td></tr>
</table>
		
<p><table border=0 cellpadding=3 cellspacing=1 bgcolor="#000000" align="center" width="600">
<tr bgcolor="#9999cc"><th bgcolor="#9999cc"> An Apt-cacher usage report has not yet been generated </th></tr>
<tr bgcolor="#cccccc"><td bgcolor="#ccccff"> Reports are generated every 24 hours. If you want reports to be generated, make sure you set '<b>generate_reports=1</b>' in <b>$configfile</b>.</td></tr>
</table>
		</body>
		</html>
EOF

	}
	else
	{
		my $usage_report = `cat $usage_file`;
		print <<EOF;
Content-Type: text/html

		$usage_report
EOF
	}
}


# Wrapper to write to the web server, to make it clearer when we are doing so.
sub write_to_server {
	my $message = shift;
  syswrite(STDOUT,$message);
}


# Jon's extra stuff to write the event to a log file.
sub writeaccesslog {
	my $cache_status = shift;
	my $new_filename = shift;

	# The format is 'time|cache status (HIT, MISS or EXPIRED)|client IP address|file size|name of requested file'
	my $time = localtime;
  my $client_ip = $ENV{REMOTE_ADDR};
  my $cached_file = "$config{cache_dir}/packages/$new_filename";
	my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks) = stat($cached_file);
	my $file_length = 0;
  $file_length+=$size if defined($size);

	open(LOGFILE,">>$config{logfile}") or die;
	print LOGFILE "$time|$client_ip|$cache_status|$file_length|$new_filename\n";
	close LOGFILE;
}

# Jon's extra stuff to write errors to a log file.
sub writeerrorlog {
	my $message = shift;
	
	my $time = localtime;
	my $client_ip = $ENV{REMOTE_ADDR};

	open(ERRORFILE,">>$config{errorfile}") or die;
	print ERRORFILE "$time|$client_ip|$message\n";
	close ERRORFILE;
}

# IP address filtering.
sub ipv4_addr_in_list ($$)
{
	return 0 if $_[0] eq '';
	debug_message ("testing $_[1]");
	return 0 unless $config{$_[1]};

	my ($client, $cfitem) = @_;
	my @allowed_hosts = split(/,\s*/, $config{$cfitem});
	for my $ahp (@allowed_hosts)
	{
		goto unknown if $ahp !~ /^[-\/,.[:digit:]]+$/;

		# single host
		if ($ahp =~ /^([^-\/]*)$/)
		{
			my $ip = $1;
			debug_message("checking against $ip");
			defined ($ip = ipv4_normalise($ip)) or goto unknown;
			return 1 if $ip eq $client;
		}
		# range of hosts (netmask)
		elsif ($ahp =~ /^([^-\/]*)\/([^-\/]*)$/)
		{
			my ($base, $mask) = ($1, $2);
			debug_message("checking against $ahp");
			defined ($base = ipv4_normalise($base)) or goto unknown;
			$mask = ($mask =~ /^\d+$/) ? make_mask ($mask, 32)
																 : ipv4_normalise ($mask);
			goto unknown unless defined $mask;
			return 1 if ($client & $mask) eq ($base & $mask);
		}
		# range of hosts (start & end)
		elsif ($ahp =~ /^([^-\/]*)-([^-\/]*)$/)
		{
			my ($start, $end) = ($1, $2);
			debug_message("checking against $start to $end");
			defined ($start = ipv4_normalise($start)) or goto unknown;
			defined ($end = ipv4_normalise($end)) or goto unknown;
			return 1 if $client ge $start && $client le $end;
		}
		# unknown
		else
		{
			unknown:
			debug_message("Alert: $cfitem ($ahp) is bad");
			write_to_server("Status: 500 Configuration error\n\n");
			exit(4);
		}
	}
	return 0; # failed
}

sub ipv6_addr_in_list ($$)
{
	return 0 if $_[0] eq '';
	debug_message ("testing $_[1]");
	return 0 unless $config{$_[1]};

	my ($client, $cfitem) = @_;
	my @allowed_hosts = split(/,\s*/, $config{$cfitem});
	for my $ahp (@allowed_hosts)
	{
		goto unknown if $ahp !~ /^[-\/,:[:xdigit:]]+$/;

		# single host
		if ($ahp =~ /^([^-\/]*)$/)
		{
			my $ip = $1;
			debug_message("checking against $ip");
			$ip = ipv6_normalise($ip);
			goto unknown if $ip eq '';
			return 1 if $ip eq $client;
		}
		# range of hosts (netmask)
		elsif ($ahp =~ /^([^-\/]*)\/([^-\/]*)$/)
		{
			my ($base, $mask) = ($1, $2);
			debug_message("checking against $ahp");
			$base = ipv6_normalise($base);
			goto unknown if $base eq '';
			goto unknown if $mask !~ /^\d+$/ || $mask < 0 || $mask > 128;
			my $m = ("\xFF" x ($mask / 8));
			$m .= chr ((-1 << (8 - $mask % 8)) & 255) if $mask % 8;
			$mask = $m . ("\0" x (16 - length ($m)));
			return 1 if ($client & $mask) eq ($base & $mask);
		}
		# range of hosts (start & end)
		elsif ($ahp =~ /^([^-\/]*)-([^-\/]*)$/)
		{
			my ($start, $end) = ($1, $2);
			debug_message("checking against $start to $end");
			$start = ipv6_normalise($start);
			$end = ipv6_normalise($end);
			goto unknown if $start eq '' || $end eq '';
			return 1 if $client ge $start && $client le $end;
		}
		# unknown
		else
		{
			unknown:
			debug_message("Alert: $cfitem ($ahp) is bad");
			write_to_server("Status: 500 Configuration error\n\n");
			exit(4);
		}
	}
	return 0; # failed
}

# Stuff to append debug messages to the error log.
sub debug_message {
	if ($config{debug} eq 1) {
		my $message = shift;

		my $time = localtime;
		my $client_ip = $ENV{REMOTE_ADDR};

		open(ERRORFILE,">>$config{errorfile}") or die;
		print ERRORFILE "$time|$client_ip|debug: $message\n";
		close ERRORFILE;
	}
}

sub setlock {
   open($exlock, $exlockfile);
   if (!flock($exlock, LOCK_EX)) {
      debug_message("unable to achieve a lock on $exlockfile: $!");
      die "Unable to achieve lock on $exlockfile: $!";
   }
}

sub unlock {
   flock($exlock, LOCK_UN);
}
 
sub get_abort_time () {
  return time () + $fetch_timeout; # five minutes from now
}
