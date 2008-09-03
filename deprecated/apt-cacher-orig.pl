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

 Copyright (C) 2001, Nick Andrew <nick@zeta.org.au>
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
directory with plenty of free space (100 - 300 Mbytes is usually
adequate).

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
it relies on the webserver supplying the PATH_INFO environment variable

3. apt-cacher.pl uses B<wget> to retrieve files, so wget must be
installed.

4. (this bug has been squashed)

5. (this bug has been squashed)

6. (this bug has been squashed)

7. (this bug has been squashed)

8. apt-get can resume a partial failed transfer, however apt-cacher.pl
cannot.

9. When wget is used with the '-c' option (to continue a partial transfer)
and the '-s' option (to write HTTP response headers to the file) it writes
the second response headers into the middle of the partial file. So we
can't use continue mode, so we have to truncate any existing file before
trying again.

10. The .deb files are stored in the cache directory with their HTTP
headers prefixed, so they cannot be directly used (e.g. you can't
do "dpkg --install $cache_dir/package-version.deb")

11. apt-cacher.pl does not issue an HTTP GET-IF-MODIFIED-SINCE request for
Packages{,.gz} and Release files, so it does not know when it has cached
an obsolete version of these files. As a workaround, there's a tuning
variable B<expire_hours>.  apt-cacher.pl will ignore any Packages.gz or
Release file which was written more than this number of hours in the past.

12. (this bug has been squashed)

=head1 ENVIRONMENT VARIABLES

B<PATH_INFO> is used to find the full URL for the requested file

B<PATH> is used to search for the wget executable

=head1 UPDATES

Please email bug fixes and enhancements to B<info@apt-cacher.org> using
B<apt-cacher> in the subject line. All reasonable changes will be
included in the next release.

The homepage for apt-cacher is
B<http://www.apt-cacher.org/>.
Please check it occasionally for updates.

=cut
# ----------------------------------------------------------------------------
use strict;
use warnings;
# Set the version number (displayed on the info page)
my $version='0.6-9';

my $path = $ENV{PATH_INFO};

# Include the library for the config file parser
require '/usr/share/apt-cacher/apt-cacher-lib.pl';

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

my $private_dir = "$config{cache_dir}/private";
my $do_lock = 0;

# use IO::Handle;
use Fcntl ':flock';
use IO::Handle;
use POSIX;

# Output data as soon as we print it
$| = 1;

# ----------------------------------------------------------------------------
# Die if we have not been configured correctly
die "apt-cacher.pl: No cache_dir directory!\n" if (!-d $config{cache_dir});
die "apt-cacher.pl: No cache_dir/tmp directory!\n" if (!-d "$config{cache_dir}/tmp");
die "apt-cacher.pl: No cache_dir/private directory!\n" if (!-d $private_dir);

# ----------------------------------------------------------------------------
# We have a problem for large packages. The problem is that it appears
# the apache webserver gets tired of waiting for us to return a document
# so it sends a SIGTERM and then soon afterward, a SIGKILL. This is
# apparently a configuration directive in mod_perl ?? Anyway, let's fork
# a child so apache's violence doesn't kill us...

if (fork() > 0) {
	# parent
	#$SIG{'PIPE'} = sub { open(E, ">>$config{cache_dir}/errs"); print E "$$ received SIGPIPE\n"; close(E); };
	$SIG{'TERM'} = sub {
		writeerrorlog("parent received SIGTERM, exiting");
		sleep(4);
		exit(8);
	};
	wait();
	exit($?);
}

# ----------------------------------------------------------------------------
# Data also used by child processes

my $unique_filename;
my $child_pid;
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

$SIG{'CHLD'} = sub {
	#print STDERR "--- apt-cacher.pl: received SIGCHLD\n";
	debug_message("received SIGCHLD");
	wait();
	$child_rc = $?;
	undef $child_pid;
};

#print STDERR "\n--- apt-cacher.pl: called with $path\n";
debug_message("called with $path");

if ($do_lock) {
	open(LOCK, ">$config{cache_dir}/lock") or die "apt-cacher.pl: Unable to open $config{cache_dir}/lock for write: $!\n";
	if (!flock(LOCK, LOCK_EX)) {
		debug_message("unable to achieve a lock on $config{cache_dir}/lock: $!");
		die "Unable to achieve lock on $config{cache_dir}/lock: $!\n";
	}

	#print STDERR "--- apt-cacher.pl: Lock achieved\n";
	debug_message("lock achieved");
	# keep LOCK open so that at most one apt-cacher.pl can be running at any time
}


# Now parse the path
if ($path eq '/report') {
       usage_report();
       exit(0);
}

if ($path !~ m(^/.+/.+)) {
	usage_error();
	exit(4);
}


my($host,$uri) = ($path =~ m(^/([^/]+)(/.+)));

if ($host eq '' || $uri eq '') {
	usage_error();
	exit(4);
}

my ($filename) = ($uri =~ /\/([^\/]+)$/);
my $new_filename;

my $is_open = 0;	# Is the file currently open by us?
my $is_incomplete = 0;	# Is the file contents complete?

if ($filename =~ /\.deb$/) {
	# Place the file in the cache with just its basename
	$new_filename = $filename;
	debug_message("new filename with just basename: $new_filename");
} else {
	# Make a long filename so we can cache these files
	$new_filename = "$host$uri";
	$new_filename =~ s/\//_/g;
	debug_message("new long filename: $new_filename");
}

my $cached_file = "$config{cache_dir}/$new_filename";

debug_message("cached file: $cached_file");

my @stat = stat($cached_file);

#print STDERR "--- Looking for $cached_file\n";
debug_message("looking for $cached_file");

my $cache_status; # = some default?

if ($filename =~ /(Packages.gz|Release)$/) {
	debug_message("filename complies: $filename");
	# Unlink the file if it is older than our configured time
	if (-f _) {
		my $now = time();
		if (@stat && int(($now - $stat[9])/3600) > $config{expire_hours}) {
			#print STDERR "--- Unlinking $new_filename because it is too old\n";
			debug_message("unlinking $new_filename because it is too old");
			# Set the status to EXPIRED so the log file can show it was downloaded again
			$cache_status = "EXPIRED";
			debug_message("$cache_status");
			unlink($cached_file);
			unlink("$private_dir/$new_filename.complete");
		}
	}
}


if (!-f $cached_file) {
	# File does not exist, so try to create it
	# KLUDGE ... probably a race condition here
	unlink("$private_dir/$new_filename.complete");
	#print STDERR "--- File does not exist, create it\n";
	debug_message("file does not exist, creating it");
	# Set the status to MISS so the log file can show it had to be downloaded
	$cache_status = "MISS";
	debug_message("$cache_status");
	if (sysopen(CF, $cached_file, O_RDWR|O_CREAT|O_EXCL, 0644)) {
		$is_open = 1;
	}
	# If open fails, maybe we came 2nd in a race
	# ... KLUDGE ... continue here
} else {
	# Set the status to HIT so the log file can show it came from cache
	### check variable scope
	$cache_status = "HIT";
	debug_message("$cache_status");
}



if (!-f $cached_file) {
	barf("Tried to create $cached_file, but failed");
}


# Ok, the file exists. Open it if we didn't already.
if (!$is_open) {
	#print STDERR "--- Open $cached_file\n";
	debug_message("open $cached_file");
	
	if (!sysopen(CF, $cached_file, O_RDWR)) {
		writeerrorlog("unable to open incomplete $cached_file: $!");
		barf("Unable to open incomplete $cached_file: $!");
	}
	$is_open = 1;
}

# Is it incomplete?
if (!-f "$private_dir/$new_filename.complete") {
	$is_incomplete = 1;
	#print STDERR "--- File is not complete\n";
	debug_message("file is not complete");
	
	if (!flock(CF, LOCK_EX|LOCK_NB)) {
		# flock failed, assume fetcher is running already
		#print STDERR "--- Unable to lock, fetcher must be running\n";
		writeerrorlog("unable to get lock, fetcher must be running");
		# KLUDGE ... race condition, wait for fetcher to start up
		sleep(3);
	} else {
		# file locked, nobody's touching it ...
		# Have to truncate it, because we can't rely on "resume"
		truncate(CF, 0);

		try_pickup($host, $uri, $cached_file, $new_filename);
	}
}

# At this point the file is open, and it's either complete or somebody
# is fetching its contents


#print STDERR "--- Starting to return $cached_file\n";
debug_message("starting to return $cached_file");

my $first_line = 1;
my($buf,$n,$bufsize);
my $abort_timer = 300;
my $nodata_count = 0;

while (1) {
	if ($sigpipe_received) {
		#print STDERR "--- Exit (SIGPIPE)\n";
		debug_message("exit (SIGPIPE)");
		exit(4);
	}
	
	seek(CF, 0, 1);
	$n = read(CF, $buf, 65536);
	barf("Oops, read failed!") if (!defined $n);

	debug_message("read $n bytes");

	if ($n < 0) {
		#print STDERR "--- Exit (read fail)\n";
		debug_message("exit (read failed)");
		exit(4);
	}

	# if ($n == 0), there's no more data to read yet
	if ($n == 0) {
		if (!$is_incomplete || ($nodata_count > 0 && -f "$private_dir/$new_filename.complete")) {
			# Looks like file is complete!
			# Finish up
			#print STDERR "--- Exit (file completed)\n";
			debug_message("exit (file completed)");

			last;
		}

		if ($nodata_count > 0 && -f "$private_dir/$new_filename.404") {
			# We must pass 404s on to the client so it knows...
			debug_message("exit (file failed, 404)");
			unlink("$private_dir/$new_filename.404");
			write_to_server("Status: 404 Received 404 in caching process\n\n");
			writeaccesslog("MISS", "$new_filename");
			exit(0);
		}

		$nodata_count += 2;
		if ($nodata_count >= $abort_timer) {
			#print STDERR "--- Abort (timeout)\n";
			debug_message("abort (timeout)");
			exit(4);
		}
		sleep(2);
		next;
	}

	$nodata_count = 0;

	# Hey, there's data! Is it the first line?
	if ($first_line) {
		my $i = index($buf, "\n");
		if ($i >= 0) {
			# Throw away first line only
			$buf = substr($buf, $i + 1);
			# Output remainder, if any
			if (length $buf) {
				write_to_server($buf);
				#print STDERR "Wrote initial ", length($buf), " bytes\n" if ($debug);
				debug_message("wrote initial " . length($buf) . " bytes");
			}
			$first_line = 0;
		} else {
			# End of first line not found, throw it all away
		}
	} else {
		write_to_server($buf);
		#print STDERR "Wrote ", length($buf), " bytes\n" if ($debug);
		debug_message("wrote " . length($buf) . " bytes");
	}
}

# Write all the stuff to the log file
writeaccesslog("$cache_status", "$new_filename");
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
<blockquote>deb http://ftp.au.debian.org/debian unstable main contrib non-free</blockquote>
becomes
<blockquote>deb http://<b>yourcache.example.com/apt-cacher/</b>ftp.au.debian.org/debian unstable main contrib non-free</blockquote>
<p>For more information on apt-cacher visit <a href="http://www.apt-cacher.org/">www.apt-cacher.org</a>.</p>
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
<tr bgcolor="#cccccc"><td bgcolor="#ccccff"> debug </td><td> $config{debug} </td></tr>
</table>

<p>
<h2 align="center">licence</h2>
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
	my $host = shift;
	my $uri = shift;
	my $cached_file = shift;
	my $new_filename = shift;

	# Otherwise, try to pick it up in the background ...

	# Set this in the parent so the parent knows what file to delete
	# if it receives a SIGTERM
	$unique_filename = "$config{cache_dir}/$new_filename";

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

	#print STDERR "--- Fetcher: Try to pick up $url\n";
	debug_message("fetcher: try to pick up $url");
	$child_pid = fork();
	barf("Fetcher: fork failed") if (!defined $child_pid);

	if ($child_pid == 0) {
		# This is the child

		# Search the PATH environment for the wget executable
		foreach my $dir (split(/:/, $ENV{PATH})) {
			my $fn = "$dir/wget";
			if (-f $fn && -x _) {
				# { } surround exec to prevent perl warning
				{
					
					# Check whether a proxy is to be used, and set the appropriate environment variable
					if ( $config{use_proxy} eq 1 && $config{http_proxy}) {
						$ENV{http_proxy} = "http://$config{http_proxy}";
					}
					# had to remove the -c option from wget because resuming is incompatible with the -s option
					exec($fn, '-s', '-nv', '-o', "$private_dir/$new_filename.err", '-O', $unique_filename, $url);
				};
			}
		}

		# dang, no wget in path
		writeerrorlog("unable to exec wget: you must have wget installed for apt-cacher to work!");
		barf("Unable to exec wget");
	}

	# Otherwise, we must be the parent

	# Child processes are reaped by signal handler
	while ($child_pid > 0) {
		pause();
	}

	my $rc = $child_rc;

	if ($rc != 0) {
		unlink($unique_filename);
	}

	#print STDERR "--- Pick up $url as $unique_filename, return code $rc\n";
	debug_message("pick up $url as $unique_filename, return code $rc");

	if ($rc != 0) {
		# Output nothing and exit - this will be a 500 server error?
		my $code = `tail -1 $private_dir/$new_filename.err`;
		$code =~ /(\d\d\d)/;
		$code = $1;

		if($code == 404) {
			open(MF, ">$private_dir/$new_filename.404");
			close(MF);
		}

		unlink("$private_dir/$new_filename.err");

		exit(0);
	}

	unlink("$private_dir/$new_filename.err");

	# Touch the new file to fix the timestamp (this fixes the bug that was previously
	# causing apt-cacher to re-download files that it thought had expired, but which
	# were actually new: thanks Raphael!)
	my $now = time;
	utime $now, $now, $unique_filename;

	# Now create the file to show the pickup is complete
	open(MF, ">$private_dir/$new_filename.complete");
	close(MF);
		
	#print STDERR "--- Fetcher exiting\n";
	debug_message("fetcher exiting");

	exit(0);
}


# Check if there has been a usage report generated and display it
sub usage_report{
	my $usage_file = "$config{logdir}/report.html";
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
<tr bgcolor="#cccccc"><td>For more information on apt-cacher visit <a href="http://www.apt-cacher.org/">www.apt-cacher.org</a>.
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
	print STDOUT $message;
}


# Jon's extra stuff to write the event to a log file.
sub writeaccesslog {
	my $cache_status = shift;
	my $new_filename = shift;

	# The format is 'time|cache status (HIT, MISS or EXPIRED)|client IP address|file size|name of requested file'
	my $time = localtime;
	my $client_ip = $ENV{REMOTE_ADDR};
	my $cached_file = "$config{cache_dir}/$new_filename";
	my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks) = stat($cached_file);
	my $file_length = 0 + $size;

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
