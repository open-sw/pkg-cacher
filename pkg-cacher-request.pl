#!/usr/bin/perl
# vim: ts=4 sw=4 ai si

=head1 NAME

 pkg-cacher - WWW proxy optimized for use with Linux Distribution Repositories

 Copyright (C) 2005 Eduard Bloch <blade@debian.org>
 Copyright (C) 2007 Mark Hindley <mark@hindley.org.uk>
 Copyright (C) 2008-2013 Robert Nelson <robertn@the-nelsons.org>
 Distributed under the terms of the GNU Public Licence (GPL).

=cut
# ----------------------------------------------------------------------------

use Fcntl qw(:DEFAULT :flock :seek);

use IO::Socket::INET;
use HTTP::Date;

use Sys::Hostname;

use File::Path;

# Set some defaults
my $static_files_regexp = '(?:'.read_patterns('static_files.regexp').')$';
my $source;

my $mode; # cgi|inetd|sa
my $concloseflag;

require 'pkg-cacher-fetch.pl';

# Data shared between files

our $cfg;
our %pathmap;

our $cached_file;
our $cached_head;
our $complete_file;
our $configfile;

our @cache_control;

# Function prototypes
sub ipv4_addr_in_list ($$);
sub ipv6_addr_in_list ($$);
sub get_abort_time ();

# Subroutines

sub sa_get_request {
	my $request_data_ref = shift;
	my $tolerated_empty_lines = 1;
	my $testpath;			# temporary, to be set by GET lines, undef on GO
	my $reqstpath;

	# reading input line by line, through the secure input method
	CLIENTLINE:
	while () {

		debug_message('Processing a new request line');

		$_ = &getRequestLine;
		debug_message("got: $_");

		if (!defined($_)) {
			exit(0);
		}

		if (/^$/) {
			if (defined($testpath)) {
				# done reading request
				$reqstpath = $testpath;
				last CLIENTLINE;
			} elsif (!$tolerated_empty_lines) {
				&sendrsp(403, 'Go away');
				exit(4);
			} else {
				$tolerated_empty_lines--;
			}
		} else {

			if (/^(GET|HEAD)\s+(\S+)(?:\s+HTTP\/(\d\.\d))?/) {
				if (defined($testpath)) {
					&sendrsp(403, 'Confusing request');
					exit(4);
				}
				$testpath = $2;
				$$request_data_ref{'httpver'} = $3;
				# also support pure HEAD calls
				if ($1 eq 'HEAD') {
					$$request_data_ref{'send_head_only'} = 1;
				}
			} elsif (/^Host:\s+(\S+)/) {
				$$request_data_ref{'hostreq'} = $1;
			} elsif (/^((?:Pragma|Cache-Control):\s*\S+)/) {
				debug_message("Request specified $1");
				push @cache_control, $1;
				if ($1=~/no-cache/) {
					$$request_data_ref{'cache_status'} = 'EXPIRED';
					debug_message("Download forced");
				}
			} elsif(/^Connection: close/i) {
				$concloseflag = 1;
			} elsif(/^Connection: .*TE/) {
				$concloseflag = 1;
			} elsif(/^Range:\s+(.*)/i) {
				$$request_data_ref{'rangereq'} = $1;
			} elsif(/^If-Range:\s+(.*)/i) {
				$$request_data_ref{'ifrange'} = $1;
			} elsif(/^If-Modified-Since:\s+(.*)/i) {
				$$request_data_ref{'ifmosince'} = $1;
			} elsif(/^\S+: [^:]*/) {
				# whatever, but valid
			} else {
				info_message("Failed to parse input: $_");
				&sendrsp(403, "Could not understand $_");
				exit(4);
			}
		}
	}

	return $reqstpath;
}

sub cgi_get_request {
	my $request_data_ref = shift;

	( $$request_data_ref{'httpver'} ) = $ENV{'SERVER_PROTOCOL'} =~ /^HTTP\/(\d+\.\d+)$/;
	$$request_data_ref{'send_head_only'} = $ENV{'REQUEST_METHOD'} eq 'HEAD';
	$$request_data_ref{'hostreq'} = $ENV{'SERVER_NAME'};
	$$request_data_ref{'rangereq'} = $ENV{'HTTP_RANGE'};
	$$request_data_ref{'ifrange'} = $ENV{'HTTP_IF_RANGE'};
	$$request_data_ref{'ifmosince'} = $ENV{'HTTP_IF_MODIFIED_SINCE'};

	if (exists $ENV{'HTTP_PRAGMA'}) {
		if ($ENV{'HTTP_PRAGMA'} =~ /no-cache/) {
			$$request_data_ref{'cache_status'} = 'EXPIRED';
		}
	}

	if (exists $ENV{'HTTP_CACHE_CONTROL'}) {
		if ($ENV{'HTTP_CACHE_CONTROL'} =~ /no-cache/) {
			$$request_data_ref{'cache_status'} = 'EXPIRED';
		}
	}

	my $cgi_path;

	# pick up the URL
	$cgi_path=$ENV{PATH_INFO};
	$cgi_path=$ENV{QUERY_STRING} if ! $cgi_path;
	$cgi_path='/' if ! $cgi_path; # set an invalid path to display infos below

	return $cgi_path;
}

sub handle_connection {
	$mode = $_[0];
	shift;
	# now begin connection's personal stuff

	my $client;
	my $filename;

	$SIG{CHLD} = 'IGNORE';

	debug_message('New '. ($mode ne 'sa' ? "\U$mode" : 'Daemon') .' connection');

	if ($mode ne 'sa') { # Not standalone daemon
		$source=*STDIN;
		$con = *STDOUT;
		# identify client in the logs.
		if (exists $ENV{REMOTE_ADDR}){ # CGI/pkg-cacher-cleanup mode
			$client=$ENV{REMOTE_ADDR};
		} else { # inetd mode
			$client='INETD';
			$cfg->{daemon_port} = &get_inetd_port();
		}
	} else { # Standalone daemon mode

		$con = shift;
		$source = $con;
		$client = $con->peerhost;
	}

	if ($mode ne 'inetd') {
		# ----------------------------------------------------------------------------
		# Let's do some security checking. We only want to respond to clients within an
		# authorized address range (127.0.0.1 and ::1 are always allowed).

		my $ip_pass = 1;
		my $ip_fail = 0;
		my $clientaddr;

		# allowed_hosts == '*' means allow all ('' means deny all)
		# denied_hosts == '' means don't explicitly deny any
		# localhost is always accepted
		# otherwise host must be in allowed list and not in denied list to be accepted

		if ($client =~ /:/) { # IPv6?
			defined ($clientaddr = ipv6_normalise ($client)) or goto badaddr;
			if (substr ($clientaddr, 0, 12) eq "\0\0\0\0\0\0\0\0\0\0\xFF\xFF") {
				$clientaddr = substr ($clientaddr, 12);
				goto is_ipv4;
			} elsif ($clientaddr eq "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\1") {
				debug_message('client is localhost');
			} else {
				$ip_pass = ($cfg->{allowed_hosts_6} =~ /^\*?$/) ||
				ipv6_addr_in_list ($clientaddr, 'allowed_hosts_6');
				$ip_fail = ipv6_addr_in_list ($clientaddr, 'denied_hosts_6');
			}
		} elsif (defined ($clientaddr = ipv4_normalise ($client))) { # IPv4?
			is_ipv4:
			if ($clientaddr eq "\x7F\0\0\1") {
				debug_message('client is localhost');
			} else {
				$ip_pass = ($cfg->{allowed_hosts} =~ /^\*?$/) ||
					ipv4_addr_in_list ($clientaddr, 'allowed_hosts');
				$ip_fail = ipv4_addr_in_list ($clientaddr, 'denied_hosts');
			}
		} else {
			goto badaddr;
		}

		# Now check if the client address falls within this range
		if ($ip_pass && !$ip_fail) {
			# Everything's cool, client is in allowed range
			debug_message("Client $client passed access control rules");
		} else {
			# Bzzzt, client is outside allowed range. Send a 403 and bail.
		badaddr:
			debug_message("Alert: client $client disallowed by access control");
			&sendrsp(403, 'Access to cache prohibited');
			exit(4);
		}
	}

	REQUEST:
	while (!$concloseflag) {

		my $reqstpath;
		my $force_download=0;
		my %request_data;

		$request_data{'httpver'} = undef;
		$request_data{'send_head_only'} = 0;
		$request_data{'hostreq'} = undef;
		$request_data{'cache_status'} = undef;
		$request_data{'rangereq'} = undef;
		$request_data{'ifrange'} = undef;
		$request_data{'ifmosince'} = undef;
	
		if ($mode eq 'cgi') {
			$reqstpath = &cgi_get_request(\%request_data);
			$concloseflag = 1;
		} else {
			$reqstpath = &sa_get_request(\%request_data);
		}

		# RFC2612 requires bailout for HTTP/1.1 if no Host
		if (!$request_data{'hostreq'} && $request_data{'httpver'} >= '1.1') {
			&sendrsp(400, 'Host Header missing');
			exit(4);
		}

		# Decode embedded ascii codes in URL
		$reqstpath =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;

		# tolerate CGI specific junk and two slashes in the beginning
		$reqstpath =~ s!^/pkg-cacher\??/!/!;
		$reqstpath =~ s!^//!/!;

		if ($reqstpath =~ m!^http://([^/]+)!) { # Absolute URI
			# Check host or proxy
			debug_message("Checking host $1 in absolute URI");
			my $sock = io_socket_inet46(PeerAddr=> $1,		# possibly with port
						PeerPort=> 80,						# Default, overridden if
															# port also in PeerAddr
						Proto   => 'tcp');
			# proxy may be required to reach host
			if (!defined($sock) && !$cfg->{use_proxy}) {
				info_message("Unable to connect to $1");
				&sendrsp(404, "Unable to connect to $1");
				exit(4);
			}
			# Both host and port need to be matched.  In inetd mode daemon_port
			# is read from inetd.conf by get_inetd_port(). CGI mode shouldn't
			# get absolute URLs.
			if (defined($sock) &&
				$sock->sockhost =~ $sock->peerhost &&
				$sock->peerport == $cfg->{daemon_port}) { # Host is this host
				debug_message('Host in Absolute URI is this server');
				$reqstpath =~ s!^http://[^/]+!!; # Remove prefix and hostname
			} else { # Proxy request
				info_message('Host in Absolute URI is not this server - proxy unsupported');
				&sendrsp(403, 'Proxy requests are not allowed');
				exit(4);
			}
			defined($sock) && $sock->shutdown(2); # Close
		}
		debug_message("Resolved request is $reqstpath");

		# Now parse the path
		if ($reqstpath =~ /^\/?report/) {
			usage_report();
			exit(0);
		}

		if ($reqstpath !~ m(^/?.+/.+)) {
			usage_error($client);
		}

		my ($host,$uri) = ($reqstpath =~ m#^/?([^/]+)(/.+)#);

		if ( !$host || !$uri ) {
			usage_error($client);
		}

		if (not exists $pathmap{$host}) { # error
			info_message("Undefined virtual host $1");
			&sendrsp(404, "Undefined virtual host $1");
			exit(4);
		}

		$uri =~ s#/{2,}#/#g; # Remove multiple separators
		($filename) = ($uri =~ /\/?([^\/]+)$/);

		if ($filename =~ /$static_files_regexp/) {
			# We must be fetching a .deb or a .rpm or some other recognised
			# file, so let's cache it.
			# Place the file in the cache with just its basename
			debug_message("base file: $filename");
		} elsif (&is_index_file($filename)) {
			# It's a Packages.gz or related file: make a long filename so we can
			# cache these files without the names colliding
			debug_message("index file: $filename");
		} else {
			# Maybe someone's trying to use us as a general purpose proxy / relay.
			# Let's stomp on that now.
			info_message("Sorry, not allowed to fetch that type of file: $filename");
			&sendrsp(403, "Sorry, not allowed to fetch that type of file: $filename");
			exit(4);
		}

		$cached_file = "$cfg->{cache_dir}/packages/$host$uri";
		$cached_head = "$cfg->{cache_dir}/headers/$host$uri";
		$complete_file = "$cfg->{cache_dir}/private/$host$uri.complete";

		foreach my $file ($cached_file, $cached_head, $complete_file) {
			my ($filepath) = $file =~ /(.*\/)[^\/]+/;

			debug_message("Checking for directory $filepath");

			if (! -d $filepath) {
				debug_message("Directory doesn't exist, creating $filepath");
				eval { mkpath($filepath) };
				if ($@) {
					info_message("Unable to create directory $filepath: $@");
					&sendrsp(403, "System error: $filename");
					exit(4);
				}
			}
		}

		debug_message("looking for $cached_file");

		if (&is_index_file($filename)) {
			debug_message("known as index file: $filename");
			# in offline mode, if not already forced deliver it as-is, otherwise check freshness
			if ($request_data{'cache_status'} ne 'EXPIRED' && -f $cached_file && -f $cached_head && !$cfg->{offline_mode}) {
				if ($cfg->{expire_hours} > 0) {
					my $now = time();
					my @stat = stat($cached_file);
					if (@stat && int(($now - $stat[9])/3600) > $cfg->{expire_hours}) {
						debug_message("unlinking $filename because it is too old");
						# Set the status to EXPIRED so the log file can show it
						# was downloaded again
						$request_data{'cache_status'} = 'EXPIRED';
						debug_message($request_data{'cache_status'});
					}
				} else {
					# use HTTP timestamping/ETag
					my ($oldmod,$newmod,$oldtag,$newtag,$testfile);
					my $response = ${&libcurl($host, $uri, undef)}; # HEAD only
					if ($response->is_success) {
						$newmod = $response->header('Last-Modified');
						$newtag = $response->header('ETag');
						if (($newmod||$newtag) && open($testfile, $cached_head)) {

							for ($newmod,$newtag) {
								s/[\n\r]//g;
							}

							for (<$testfile>) {
								if (/^.*Last-Modified:\s(.*)(?:\r|\n)/) {
								  $oldmod = $1;
								} elsif (/^.*ETag:\s*(.*)(?:\r|\n)/) {
								  $oldtag = $1;
								}
								last if $oldtag && $oldmod;
							}
							close($testfile);
						}
# Don't use ETag by default for now: broken on some servers
						if ($cfg->{use_etags} && $oldtag && $newtag) { # Try ETag first
							if ($oldtag eq $newtag) {
							  debug_message("ETag headers match, $oldtag <-> $newtag. Cached file unchanged");
							} else {
							  debug_message("ETag headers different, $oldtag <-> $newtag. Refreshing cached file");
							  $request_data{'cache_status'} = 'EXPIRED';
							  debug_message($request_data{'cache_status'});
							}
						} else {
							if ($oldmod && (str2time($oldmod) >= str2time($newmod)) ) {
# that's ok
								debug_message("cached file is up to date or more recent, $oldmod <-> $newmod");
							} else {
								debug_message("downloading $filename because more recent version is available: $oldmod <-> $newmod");
								$request_data{'cache_status'} = 'EXPIRED';
								debug_message($request_data{'cache_status'});
							}
						}
					} else {
						info_message('HEAD request error: '.$response->status_line.' Reusing existing file');
						$request_data{'cache_status'} = 'OFFLINE';
					}
				}
			}
		}
	
		# handle if-range
		# We don't support if-range so if it is specified we need to always 
		# treat the file as expired and send the whole thing.
		if ($request_data{'ifrange'}) {
			$request_data{'rangereq'} = undef;
		}

		# handle if-modified-since in a better way (check the equality of
		# the time stamps). Do only if download not forced above.

		if ($request_data{'ifmosince'} && $request_data{'cache_status'} ne 'EXPIRED') {
			$request_data{'ifmosince'} =~ s/\n|\r//g;

			my $oldhead;
			if (open(my $testfile, $cached_head)) {
				LINE:
				for(<$testfile>){
					if(/^.*Last-Modified:\s(.*)(?:\r|\n)/) {
						$oldhead = $1;
						last LINE;
					}
				}
				close($testfile);
			}

			if ($oldhead && str2time($request_data{'ifmosince'}) >= str2time($oldhead)) {
				&sendrsp(304, 'Not Modified');
				debug_message("File not changed: $request_data{'ifmosince'}");
				next REQUEST;
			}
		}

		&set_global_lock(': file download decision'); # file state decisions, lock that area

		my $fromfile; # handle for return_file()

		# download or not decision. Also releases the global lock
		dl_check:
		if (!$force_download && -e $cached_head && -e $cached_file && !$request_data{'cache_status'}) {
			if (!sysopen($fromfile, $cached_file, O_RDONLY)) {
				&release_global_lock;
				barf("Unable to open $cached_file: $!.");
			}
			if (-f $complete_file) {
				# not much to do if complete
				$request_data{'cache_status'} = 'HIT';
				debug_message($request_data{'cache_status'});
			} else {
				# a fetcher was either not successful or is still running
				# look for activity...
				if (flock($fromfile, LOCK_EX|LOCK_NB)) {
					flock($fromfile, LOCK_UN);
					# No fetcher working on this package. Redownload it.
					close($fromfile);
					undef $fromfile;
					debug_message('no fetcher running, downloading');
					$force_download=1;
					goto dl_check;
				} else {
					debug_message('Another fetcher already working on file');
				}
			}
			&release_global_lock;
		} else {
			# bypass for offline mode, no forking, just report the "problem"
			if ($cfg->{offline_mode}) {
				&release_global_lock;
				&sendrsp(503, 'Service not available: pkg-cacher offline');
				next REQUEST;
			}
			# (re) download them
			unlink($cached_file, $cached_head, $complete_file);
			debug_message('file does not exist or download required, forking fetcher');
			# Create the file, it will reopened in fetch_store
			sysopen(my $pkfd, $cached_file, O_RDWR|O_CREAT|O_EXCL, 0644)
				|| barf("Unable to create new $cached_file: $!");
			close($pkfd);
			sysopen($fromfile, $cached_file, O_RDONLY)
				|| barf("Unable to open $cached_file: $!.");
			# Set the status to MISS so the log file can show it had to be downloaded
			if (!defined($request_data{'cache_status'})) { # except on special presets from index file checks above
				$request_data{'cache_status'} = 'MISS';
				debug_message($request_data{'cache_status'});
			}

			&fetch_store ($host, $uri);	# releases the global lock
										# after locking the target
										# file
		}

		debug_message('checks done, can return now');
		my $ret = &return_file ($request_data{'send_head_only'} ? undef : \$fromfile, $request_data{'rangereq'});
		if ($ret==2) { # retry code
			debug_message('return_file requested retry');
			goto dl_check;
		}
		debug_message('Package sent');

		# Write all the stuff to the log file
		writeaccesslog($request_data{'cache_status'}, $filename, -s $cached_file, $client);
	}
}

sub parse_range {
	my @result;
	my ($input_ranges) = $_[0] =~ /^bytes=([\d,-]+)$/i;

	debug_message("parse_range: input_ranges = $input_ranges");

	if ($input_ranges) {
		HANDLE_RANGE:
		foreach my $range (split /,/,$input_ranges) {
			my ($start, $end, $single) = $range =~ /^(\d+)?-(\d+)?$|^(\d+)$/;

			debug_message("parse_range: start = $start, end = $end, single = $single");

			if ($single) {
				$start = $end = $single;
			}

			if ($start && $end && $start > $end) {
				@result = [ 0, undef ];
				last HANDLE_RANGE;
			}
			push @result, [ $start, $end ];
		}
	} else {
		@result = [ 0, undef ];
	}
	return @result;
}

sub return_file {
	# At this point the file is open, and it's either complete or somebody
	# is fetching its contents

	my $fromfile = ${$_[0]};
	my $range = $_[1];
	my $header_printed = 0;

	my $abort_time = get_abort_time();
	my $buf;

	my @range_list;
	my $total_length;

	my $status_header;
	my $fixed_headers;
	my $complete_found;

	if ($range) {
		@range_list = parse_range($range);
	} else {
		@range_list = [ 0, undef ]
	}

	#
	# Wait for the header and then read it
	# 
	my $code;
	my $msg;

	WAIT_FOR_HEADER:
	while () {
		if (time() > $abort_time) {
			info_message("return_file $cached_file aborted waiting for header");
			&sendrsp(504, 'Request Timeout')
				if !$header_printed;
			exit(4);
		}

		if (-s $cached_head) {
			# header file seen, protect the reading
			&set_global_lock(': reading the header file');
			if (! -f $cached_head) {
				# file removed while waiting for lock - download failure?!
				# start over, maybe spawning an own fetcher
				&release_global_lock;
				return(2); # retry
			}

			open(my $in, $cached_head) || die $!;

			$status_header = <$in>; # read exactly one status line

			($code, $msg) = ($status_header =~ /^HTTP\S+\s+(\d+)\s(.*)/);
			
			if ($code == 302) {
				# We got a redirect, wait for the fetcher to process it.
				info_message('return_file got redirect');
				for (<$in>) {
					if (/^Location:\ *([\S]+)/) {
						info_message("New location: $1");
					}
				}
				close($in);
				&release_global_lock;
				sleep(2);
				next WAIT_FOR_HEADER;
			}

			# keep only interesting parts
			$fixed_headers="";
			for (<$in>) {
				if (/^Last-Modified|Content|Accept|ETag|Age/) {
					if (/^Content-Length:\ *(\d+)/) {
						$total_length = $1;
					} else {
						$fixed_headers .= $_;
					}
				}
			}

			close($in);
			&release_global_lock;

			last WAIT_FOR_HEADER;
		}
		sleep(1);
	}

	# alternative for critical errors
	if (!defined($code)) {
		($code, $msg) = ($status_header =~ /^(5\d\d)\s(.*)/);
	}

	if (!defined($code)) {
		info_message("Faulty header file detected: $cached_head, first line was: $status_header");
		unlink $cached_head;
		&sendrsp(500, 'Internal Server Error');
		exit(3);
	}

	# in CGI mode, use alternative status line. Don't print one
	# for normal data output (apache does not like that) but on
	# abnormal codes, and then exit immediately
	if ($mode eq 'cgi' && $code != 200) {
		# don't print the head line but a Status on errors instead
		print $con "Status: $code $msg\n\n";
		exit(1);
	}

	# keep alive or not?
	# If error, force close
	if ($code != 200) {
		debug_message("Got $code error. Going to close connection.");

		$status_header .= "Connection: Close\r\n";
		print $con $status_header."\r\n";
		# Stop after sending the header with errors
		return;
	}

	# Otherwise follow the client
	$fixed_headers .= 'Connection: '.($concloseflag ? 'Close' : 'Keep-Alive')."\r\n";

	if (!$fromfile) {
		$status_header .= $fixed_headers;
		print $con $status_header."\r\n";
		# pure HEAD request, we are done
		return;
	}

	#
	# Process range list
	# 	Fill in start for range relative to the end.
	# 	Verify that at least one range overlaps the file.
	# 
	my $no_valid_ranges = 1;

	foreach my $range_entry (@range_list) {
		my $begin = $range_entry->[0];
		my $end = $range_entry->[1];
			if ($begin == undef) {
			# last n bytes of file
			$begin = $total_length - $end;
			if ($begin < 0) {
				$begin = 0;
			}
			$end = undef;
			$no_valid_ranges = 0;
		} elsif ($begin < $total_length) {
			$no_valid_ranges = 0;
		}
    }

	if ($no_valid_ranges) {
		if ($mode eq 'cgi') {
			$status_header = "Status: 416 Requested Range Not Satisfiable\r\n";
		} else {
			$status_header = "HTTP/1.1 416 Requested Range Not Satisfiable\r\n";
		}
		$status_header .= "Connection: Close\r\n";
		print $con $status_header."\r\n";
		return;
	}

	debug_message("ready to send contents of $cached_file");

	RANGE_ENTRY: foreach my $range_entry (@range_list) {

		my $begin = $range_entry->[0];
		my $end = $range_entry->[1];

		debug_message("begin = $begin, end = $end");

		next RANGE_ENTRY if ($begin >= $total_length);
			
		# needs to print the header first
		$header_printed = 0;
		my $range_start = $begin;
		my $range_length;

		if ($end == undef || $end > $total_length) {
			$range_length = $total_length - $range_start;
		} else {
			$range_length = $end - $begin + 1;
		}

		debug_message("range_start = $range_start, range_length = $range_length");

		CHUNK:
		while (1) {

			if (time() > $abort_time) {
				info_message("return_file $cached_file aborted by timeout at $range_start of $total_length bytes");
				&sendrsp(504, 'Request Timeout') if !$header_printed;
				exit(4);
			}

			if (!$header_printed) {
				# in CGI mode, use alternative status line. Don't print one
				# for normal data output (apache does not like that) but on
				# abnormal codes, and then exit immediately
				my $headers = '';

				if ($begin != 0 || $end != undef) {
					if ($mode eq 'cgi') {
						$headers = "Status: 206 Partial Content\r\n";
					} else {
						$headers = "HTTP/1.1 206 Partial Content\r\n";
					}
					$headers .= 'Content-Range: bytes '.$range_start.'-'.($range_start+$range_length-1).'/'.$total_length."\r\n";
				} else {
					if ($mode ne 'cgi') {
						$headers = $status_header;
					}
				}

				$headers .= 'Content-Length: '.$range_length."\r\n";

				$headers .= $fixed_headers;

				print $con $headers."\r\n";

				$header_printed = 1;
				debug_message("Header sent: $headers");
			}

			my $new_pos = sysseek($fromfile, $range_start, SEEK_SET);

			debug_message("new_pos = $new_pos");

			if ($new_pos != $range_start) {
				# Still waiting for this part of the file to download
				sleep 1;
				next CHUNK;
			}

			my $read_length = $range_length < 65536 ? $range_length : 65536;

			my $n = sysread($fromfile, $buf, $read_length);

			debug_message("read $n bytes");

			if (!defined($n)) {
				debug_message('Error detected, closing connection');
				exit(4); # Header already sent, can't notify error
			}

			if ($n == 0) {

				if ($complete_found) {
					# complete file was found in the previous iteration
-                   # this is the loop exit condition
					last CHUNK;
				}

				if (-f $complete_file) {
					# do another iteration, may need to read remaining data
					debug_message('complete file found');
					$complete_found=1;
					next CHUNK;
				}

				# debug_message('waiting for new data');
				# wait for fresh data
				sleep(1);
				next CHUNK;

			} else {
				$range_length -= $n;
				$range_start += $n;

				#debug_message("write $n / $curlen bytes");
				# send data and update watchdog
				print $con $buf;
				debug_message("wrote $n (sum: ".($range_start - $begin).' bytes)');
				$abort_time = get_abort_time();

				next RANGE_ENTRY if ($range_length == 0);
			}
		}
	}
}

sub get_abort_time () {
	return time () + $cfg->{fetch_timeout}; # five minutes from now
}

# Check if there has been a usage report generated and display it
sub usage_report {
	my $usage_file = "$cfg->{logdir}/report.html";
	&sendrsp(200, 'OK', 'Content-Type', 'text/html', 'Expires', 0);
	if (!-f $usage_file) {
		print $con <<EOF;

<html>
<title>Pkg-cacher traffic report</title><style type="text/css"><!--
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
<tr bgcolor="#9999cc"><td> <h1>Pkg-cacher traffic report</h1> </td></tr>
</td></tr>
</table>

<p><table border=0 cellpadding=3 cellspacing=1 bgcolor="#000000" align="center" width="600">
<tr bgcolor="#9999cc"><th bgcolor="#9999cc"> An Pkg-cacher usage report has not yet been generated </th></tr>
<tr bgcolor="#cccccc"><td bgcolor="#ccccff"> Reports are generated every 24 hours. If you want reports to be generated, make sure you set '<b>generate_reports=1</b>' in <b>$configfile</b>.</td></tr>
</table>
		</body>
		</html>
EOF

    } else {
		open(my $usefile, $usage_file) || die $!;
		my @usedata = <$usefile>;
		close($usefile);
		print $con @usedata;
	}
}

# IP address filtering.
sub ipv4_addr_in_list ($$) {
	return(0) if $_[0] eq '';
	debug_message ("testing $_[1]");
	return(0) unless $cfg->{$_[1]};

	my ($client, $cfitem) = @_;
	my @allowed_hosts = split(/\s*[;,]\s*/, $cfg->{$cfitem});
	for my $ahp (@allowed_hosts) {
	    goto unknown if $ahp !~ /^[-\/,.[:digit:]]+$/;

	    if ($ahp =~ /^([^-\/]*)$/) {
			# single host
			my $ip = $1;
			debug_message("checking against $ip");
			defined ($ip = ipv4_normalise($ip)) or goto unknown;
			return(1) if $ip eq $client;
		} elsif ($ahp =~ /^([^-\/]*)\/([^-\/]*)$/) {
			# range of hosts (netmask)
			my ($base, $mask) = ($1, $2);
			debug_message("checking against $ahp");
			defined ($base = ipv4_normalise($base)) or goto unknown;
			$mask = ($mask =~ /^\d+$/) ? make_mask ($mask, 32)
				: ipv4_normalise ($mask);
			goto unknown unless defined $mask;
			return(1) if ($client & $mask) eq ($base & $mask);
		} elsif ($ahp =~ /^([^-\/]*)-([^-\/]*)$/) {
			# range of hosts (start & end)
			my ($start, $end) = ($1, $2);
			debug_message("checking against $start to $end");
			defined ($start = ipv4_normalise($start)) or goto unknown;
			defined ($end = ipv4_normalise($end)) or goto unknown;
			return(1) if $client ge $start && $client le $end;
		} else {
			# unknown
		unknown:
			debug_message("Alert: $cfitem ($ahp) is bad");
			&sendrsp(500, 'Configuration error');
			exit(4);
		}
	}
	return(0); # failed
}

sub ipv6_addr_in_list ($$) {
	return(0) if $_[0] eq '';
	debug_message ("testing $_[1]");
	return(0) unless $cfg->{$_[1]};

	my ($client, $cfitem) = @_;
	my @allowed_hosts = split(/\s*[;,]\s*/, $cfg->{$cfitem});
	for my $ahp (@allowed_hosts) {
		goto unknown if $ahp !~ /^[-\/,:[:xdigit:]]+$/;

		if ($ahp =~ /^([^-\/]*)$/) {
			# single host
			my $ip = $1;
			debug_message("checking against $ip");
			$ip = ipv6_normalise($ip);
			goto unknown if $ip eq '';
			return(1) if $ip eq $client;
		} elsif ($ahp =~ /^([^-\/]*)\/([^-\/]*)$/) {
			# range of hosts (netmask)
			my ($base, $mask) = ($1, $2);
			debug_message("checking against $ahp");
			$base = ipv6_normalise($base);
			goto unknown if $base eq '';
			goto unknown if $mask !~ /^\d+$/ || $mask < 0 || $mask > 128;
			my $m = ("\xFF" x ($mask / 8));
			$m .= chr ((-1 << (8 - $mask % 8)) & 255) if $mask % 8;
			$mask = $m . ("\0" x (16 - length ($m)));
			return(1) if ($client & $mask) eq ($base & $mask);
		} elsif ($ahp =~ /^([^-\/]*)-([^-\/]*)$/) {
			# range of hosts (start & end)
			my ($start, $end) = ($1, $2);
			debug_message("checking against $start to $end");
			$start = ipv6_normalise($start);
			$end = ipv6_normalise($end);
			goto unknown if $start eq '' || $end eq '';
			return(1) if $client ge $start && $client le $end;
		} else {
			# unknown
		unknown:
			debug_message("Alert: $cfitem ($ahp) is bad");
			&sendrsp(500, 'Configuration error');
			exit(4);
		}
	}
	return(0); # failed
}

sub sendrsp {
	my $code=shift;
	my $msg=shift;
	$msg='' if !defined($msg);

	my $initmsg = ($mode eq 'cgi') ?
		"Status: $code $msg\r\n" :
		"HTTP/1.1 $code $msg\r\n";

	$initmsg.="Connection: Keep-Alive\r\nAccept-Ranges: bytes\r\nKeep-Alive: timeout=15, max=100\r\n" if ($code != 403);

	#debug_message("Sending Response: $initmsg");
	print $con $initmsg;

	my $altbit=0;
	for (@_) {
		$altbit=!$altbit;
		if ($altbit) {
			#debug_message("$_: ");
			print $con "$_: ";
		} else {
			#debug_message("$_\r\n");
			print $con "$_\r\n";
		}
	}
	print $con "\r\n";
}

# DOS attack safe input reader
my @reqLineBuf;
my $reqTail;
sub getRequestLine {
	# if executed through a CGI wrapper setting a flag variable
	if (!@reqLineBuf) {
		my $buf='';

		# after every read at least one line MUST have been found. Read length
		# is large enough.

		my $n=sysread($source, $buf, 1024);
		$buf=$reqTail.$buf if(defined($reqTail));
		undef $reqTail;

		# pushes the lines found into the buffer. The last one may be incomplete,
		# extra handling below
		push(@reqLineBuf, split(/\r\n/, $buf, 1000) );

		# buf did not end in a line terminator so the last line is an incomplete
		# chunk. Does also work if \r and \n are separated
		if (substr($buf, -2) ne "\r\n") {
			$reqTail=pop(@reqLineBuf);
		}
	}
	return shift(@reqLineBuf);
}

sub get_inetd_port {
	# Does not handle multiple entries
	# I don't know how to find which one would be correct
	my $inetdconf = '/etc/inetd.conf';
	my $xinetdconf = '/etc/xinetd.conf';
	my $xinetdconfdir = '/etc/xinetd.d';
	my $port;

	if (-f $inetdconf && -f '/var/run/inetd.pid') {
		open(FILE, $inetdconf) || do {
			info_message("Warning: Cannot open $inetdconf, $!");
			return;
		};
		while (<FILE>) {
			next if /^(?:#|$)/; # Weed comments and empty lines
			if (/^\s*(\S+)\s+.*pkg-cacher/) {
				$port = $1;
				last;
			}
		}
		close (FILE);
		info_message("Warning: no pkg-cacher port found in $inetdconf") if !$port;
	} elsif ( -f '/var/run/xinetd.pid' && -f $xinetdconfdir || -f $xinetdconf ) {
		my $ident;
		my $found;
		FILE:
		for ($xinetdconf, <$xinetdconfdir/*>) {
			open(FILE, $_) || do {
				info_message("Warning: Cannot open $_, $!"); next;
			};
			LINE:
			while (<FILE>) {
				next LINE if /^(?:#|$)/; # Weed comments and empty lines
				if (/^\s*service\s+(\S+)/) {
					$ident = $1;
					next LINE;
				}
				$found += /^\s+server(?:_args)?\s*=.*pkg-cacher/;
				if (/^\s+port\s*=\s*(\d+)/) {
					$ident = $1;
				}
			}
			close (FILE);
			if ($found) {
				$port = $ident;
				debug_message("Found inetd port match $port");
				last FILE;
			}
		}
		info_message("Warning: no pkg-cacher port found in $xinetdconf") if !$found;
	} else {
		info_message('Warning: no running inetd server found');
	}
	return $port;
}

1;
