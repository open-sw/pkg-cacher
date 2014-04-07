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

use Fcntl qw(:DEFAULT :flock SEEK_SET SEEK_CUR SEEK_END);

use WWW::Curl::Easy;
use IO::Socket::INET;
use HTTP::Response;
use HTTP::Date;

use Sys::Hostname;

use File::Path;

# Data shared between files

our $version;
our $cfg;
our %pathmap;

our $cached_file;
our $cached_head;
our $complete_file;

our @cache_control;

# Subroutines

sub head_callback {
	my $chunk = $_[0];
	my $response = ${$_[1][0]};
	my $write = $_[1][1];

	SWITCH:
	for ($chunk) {
		/^HTTP/ && do {
			my ($proto,$code,$mess) = split(/ /, $chunk, 3);
			$response->protocol($proto);
			$response->code($code);
			$response->message($mess);
			last SWITCH;
		};
		/^\S+: \S+/ && do {
			# debug_message("fetch: Got header $chunk\n");
			$response->headers->push_header(split /: /, $chunk);
			last SWITCH;
		};
		/^\r\n$/ && do {
			debug_message("fetch: libcurl download of headers complete");
			&write_header(\$response) if $write;
			last SWITCH;
		};
		info_message("fetch: warning, unrecognised line in head_callback: $chunk");
	}
	return length($chunk); # OK
}

# Arg is ref to HTTP::Response
sub write_header {
	&set_global_lock(": libcurl, storing the header to $cached_head");
	open (my $chfd, ">$cached_head") || barf("Unable to open $cached_head, $!");
	print $chfd ${$_[0]}->as_string;
	close($chfd);
	&release_global_lock;
}

sub body_callback {
	my ($chunk, $handle) = @_;

	# debug_message("fetch: Body callback got ".length($chunk)." bytes for $handle\n");

	# handle is undefined if HEAD, in that case body is usually an error message
	if (defined $handle) {
		print $handle $chunk || return -1;
	}

	return length($chunk); # OK
}

sub debug_callback {
	my ($data, undef, $type) = @_;
	writeerrorlog "debug CURLINFO_"
		.('TEXT','HEADER_IN','HEADER_OUT','DATA_IN','DATA_OUT','SSL_DATA_IN','SSL_DATA_OUT')[$type]
		." [$$]: $data" if ($type < $cfg->{debug});
}

{
	my $curl; # Make static
	sub setup_curl {

		return \$curl if (defined($curl));
		
		debug_message('fetch: init new libcurl object');
		$curl = WWW::Curl::Easy->new();

		# General
		$curl->setopt(CURLOPT_USERAGENT, "pkg-cacher/$version (".$curl->version.')');
		$curl->setopt(CURLOPT_NOPROGRESS, 1);
		$curl->setopt(CURLOPT_CONNECTTIMEOUT, 10);
		$curl->setopt(CURLOPT_NOSIGNAL, 1);
		$curl->setopt(CURLOPT_LOW_SPEED_LIMIT, 0);
		$curl->setopt(CURLOPT_LOW_SPEED_TIME, $cfg->{fetch_timeout});
		$curl->setopt(CURLOPT_INTERFACE, $cfg->{use_interface})
			if defined $cfg->{use_interface};

		# Callbacks
		$curl->setopt(CURLOPT_WRITEFUNCTION, \&body_callback);
		$curl->setopt(CURLOPT_HEADERFUNCTION, \&head_callback);

		# Disable this, it isn't supported on Debian Etch
		# $curl->setopt(CURLOPT_DEBUGFUNCTION, \&debug_callback);
		# $curl->setopt(CURLOPT_VERBOSE, $cfg->{debug});

		# SSL
		if (! $cfg->{require_valid_ssl}) {
			$curl->setopt(CURLOPT_SSL_VERIFYPEER, 0);
			$curl->setopt(CURLOPT_SSL_VERIFYHOST, 0);
		}
		
		# Rate limit support
		my $maxspeed;
		for ($cfg->{limit}) {
			/^\d+$/ && do { $maxspeed = $_; last; };
			/^(\d+)k$/ && do { $maxspeed = $1 * 1024; last; };
			/^(\d+)m$/ && do { $maxspeed = $1 * 1048576; last; };
			warn "Unrecognised limit: $_. Ignoring.";
		}
		if ($maxspeed) {
			debug_message("fetch: Setting bandwidth limit to $maxspeed");
			$curl->setopt(CURLOPT_MAX_RECV_SPEED_LARGE, $maxspeed);
		}

		return \$curl;
	}
}

# runs the get or head operations on the user agent
sub libcurl {
	my ($vhost, $uri, $pkfdref) = @_;

	my $url;
	my $curl = ${&setup_curl};

	my $hostcand;
	my $response;
	my @headers;

	if (! grep /^Pragma:/, @cache_control) {
		# Remove libcurl default.
		push @headers, 'Pragma:';
	} else {
		push @headers, @cache_control;
	}

	my @hostpaths = @{$pathmap{$vhost}};

	PROCESS_HOST: while () {
		$response = HTTP::Response->new();

		# make the virtual hosts real. 
		$hostcand = shift(@hostpaths);
		debug_message("fetch: Candidate: $hostcand");
		$url = $hostcand = ($hostcand =~ /^https?:/ ? '' : 'http://').$hostcand.$uri;

		# Proxy - SSL or otherwise - Needs to be set per host
		if ($url =~ /^https:/) {
			$curl->setopt(CURLOPT_PROXY, $cfg->{https_proxy})
				if ($cfg->{use_proxy} && $cfg->{https_proxy});
			$curl->setopt(CURLOPT_PROXYUSERPWD, $cfg->{https_proxy_auth})
				if ($cfg->{use_proxy_auth});
		} else {
			$curl->setopt(CURLOPT_PROXY, $cfg->{http_proxy})
				if ($cfg->{use_proxy} && $cfg->{http_proxy});
			$curl->setopt(CURLOPT_PROXYUSERPWD, $cfg->{http_proxy_auth})
				if ($cfg->{use_proxy_auth});
		}
		my $redirect_count = 0;
		my $retry_count = 0;

		while () {
			if (!$pkfdref) {
				debug_message ('fetch: setting up for HEAD request');
				$curl->setopt(CURLOPT_NOBODY,1);
			} else {
				debug_message ('fetch: setting up for GET request');
				$curl->setopt(CURLOPT_HTTPGET,1);
				$curl->setopt(CURLOPT_FILE, $$pkfdref);
			}

			$curl->setopt(CURLOPT_HTTPHEADER, \@headers);
			$curl->setopt(CURLOPT_WRITEHEADER, [\$response, ($pkfdref ? 1 : 0)]);
			$curl->setopt(CURLOPT_URL, $url);

			debug_message("fetch: getting $url");

			if ($curl->perform) { # error
				$response = HTTP::Response->new(502);
				$response->protocol('HTTP/1.1');
				$response->message('pkg-cacher: libcurl error: '.$curl->errbuf);
				error_message("fetch: error - libcurl failed for $url with ".$curl->errbuf);
				write_header(\$response); # Replace with error header
			}

			$response->request($url);

			my $httpcode = $curl->getinfo(CURLINFO_HTTP_CODE);

			if ($httpcode == 000 || $httpcode == 400) {
				$retry_count++;
				if ($retry_count > 5) {
					info_message("fetch: retry count exceeded, trying next host in path_map");
					last;
				}

				info_message("fetch: Retrying due to bad request or no response code from $url");

				$url = $hostcand;

			} elsif ($response->is_redirect()) {
				$redirect_count++;
				if ($redirect_count > 5) {
					info_message("fetch: redirect count exceeded, trying next host in path_map");
					last;
				}

				my $newurl = $response->header("Location");

				if ($newurl =~ /^ftp:/) {
					# Redirected to an ftp site which won't work, try again
					info_message("fetch: ignoring redirect from $url to $newurl");
					$url = $hostcand;
				} else {
					info_message("fetch: redirecting from $url to $newurl");
					$url = $newurl;
				}
			} else {
				# It isn't a redirect or a malformed response so we are done
				last;
			}

			$response = HTTP::Response->new();
			if ($pkfdref) {
				truncate($$pkfdref, 0);
				sysseek($$pkfdref, 0, 0);
			}
			unlink($cached_head, $complete_file);
		}

		# if okay or the last candidate fails return
		if ($response->is_success || ! @hostpaths ) {
			last;
		}

		# truncate cached_file to remove previous HTTP error
		if ($pkfdref) {
			truncate($$pkfdref, 0);
			sysseek($$pkfdref, 0, 0);
		}
	}

	debug_message("fetch: libcurl response =\n".$response->as_string."\n");

	return \$response;
}

sub fetch_store {
	my ($host, $uri) = @_;
	my $response;
	my $pkfd;
	my $filename;

	($filename) = ($uri =~ /\/?([^\/]+)$/);

	my $url = "http://$host$uri";
	debug_message("fetch: try to fetch $url");

	sysopen(my $pkfd, $cached_file, O_RDWR)
		|| barf("Unable to open $cached_file for writing: $!");

	# jump from the global lock to a lock on the target file
	flock($pkfd, LOCK_EX) || barf('Unable to lock the target file');
	&release_global_lock;

	$response = ${&libcurl($host, $uri, \$pkfd)};	

	flock($pkfd, LOCK_UN);
	close($pkfd) || warn "Close $cached_file failed, $!";

	debug_message('fetch: libcurl returned');

	if ($response->is_success) {
		debug_message("fetch: stored $url as $cached_file");

		# sanity check that file size on disk matches the content-length in the header
		my $expected_length = -1;
		if (open(my $chdfd, $cached_head)) {
			LINE:
			for(<$chdfd>){
				if(/^Content-Length:\s*(\d+)/) {
					$expected_length = $1;
					last LINE;
				}
			}
			close($chdfd);
		}

		my $file_size = -s $cached_file;

		if ($expected_length != -1) {
			if ($file_size != $expected_length) {
				unlink($cached_file);
				barf("$cached_file is the wrong size, expected $expected_length, got $file_size");
			}
		} else {
			# There was no Content-Length header so chunked transfer, manufacture one
			open (my $chdfd, ">>$cached_head") || barf("Unable to open $cached_head, $!");
			printf $chdfd "Content-Length: %d\r\n", $file_size;
			close($chdfd);
		}

		# assuming here that the filesystem really closes the file and writes
		# it out to disk before creating the complete flag file

		my $sha1sum = `sha1sum $cached_file`;

		if (!$sha1sum) {
			barf("Unable to calculate SHA-1 sum for $cached_file - error = $?");
		}

		($sha1sum) = $sha1sum =~ /([0-9A-Fa-f]+) +.*/;

		debug_message("fetch: sha1sum $cached_file = $sha1sum");

		&set_global_lock(': link to cache');
		
		if (-f "$cfg->{cache_dir}/cache/$filename.$sha1sum") {
			unlink($cached_file);
			link("$cfg->{cache_dir}/cache/$filename.$sha1sum", $cached_file);
		} else {
			link($cached_file, "$cfg->{cache_dir}/cache/$filename.$sha1sum");
		}

		&release_global_lock;

		debug_message("fetch: setting complete flag for $filename");
		# Now create the file to show the pickup is complete, also store the original URL there
		open(MF, ">$complete_file") || die $!;
		print MF $response->request;
		close(MF);
	} elsif (HTTP::Status::is_client_error($response->code)) {
		debug_message('fetch: upstream server returned error '.$response->code." for ".$response->request.". Deleting $cached_file.");
		unlink $cached_file;
	}
	debug_message('fetch: fetcher done');
}

1;
