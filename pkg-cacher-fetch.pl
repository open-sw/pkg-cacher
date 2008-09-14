#!/usr/bin/perl
# vim: ts=4 sw=4 ai si

=head1 NAME

 pkg-cacher - WWW proxy optimized for use with Linux Distribution Repositories

 Copyright (C) 2005 Eduard Bloch <blade@debian.org>
 Copyright (C) 2007 Mark Hindley <mark@hindley.org.uk>
 Copyright (C) 2008 Robert Nelson <robertn@the-nelsons.org>
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
			# debug_message("Got header $chunk\n");
			$response->headers->push_header(split /: /, $chunk);
			last SWITCH;
		};
		/^\r\n$/ && do {
			debug_message("libcurl download of headers complete");	
			&write_header(\$response) if $write;
			last SWITCH;
		};
		info_message("Warning, unrecognised line in head_callback: $chunk");
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

	# debug_message("Body callback got ".length($chunk)." bytes for $handle\n");
	print $handle $chunk || return -1;

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
		
		debug_message('Init new libcurl object');
		$curl=new WWW::Curl::Easy;

		# General
		$curl->setopt(CURLOPT_USERAGENT, "pkg-cacher/$version ".$curl->version);
		$curl->setopt(CURLOPT_NOPROGRESS, 1);
		$curl->setopt(CURLOPT_CONNECTTIMEOUT, 60);
		$curl->setopt(CURLOPT_NOSIGNAL, 1);
		$curl->setopt(CURLOPT_LOW_SPEED_LIMIT, 0);
		$curl->setopt(CURLOPT_LOW_SPEED_TIME, $cfg->{fetch_timeout});
		$curl->setopt(CURLOPT_INTERFACE, $cfg->{use_interface}) if defined $cfg->{use_interface};

		# Callbacks
		$curl->setopt(CURLOPT_WRITEFUNCTION, \&body_callback);
		$curl->setopt(CURLOPT_HEADERFUNCTION, \&head_callback);
		$curl->setopt(CURLOPT_DEBUGFUNCTION, \&debug_callback);
		$curl->setopt(CURLOPT_VERBOSE, $cfg->{debug});

		# Proxy
		$curl->setopt(CURLOPT_PROXY, $cfg->{http_proxy})
			if ($cfg->{use_proxy} && $cfg->{http_proxy});
		$curl->setopt(CURLOPT_PROXYUSERPWD, $cfg->{http_proxy_auth})
			if ($cfg->{use_proxy_auth});
		
		# Rate limit support
		my $maxspeed;
		for ($cfg->{limit}) {
			/^\d+$/ && do { $maxspeed = $_; last; };
			/^(\d+)k$/ && do { $maxspeed = $1 * 1024; last; };
			/^(\d+)m$/ && do { $maxspeed = $1 * 1048576; last; };
			warn "Unrecognised limit: $_. Ignoring.";
		}
		if ($maxspeed) {
			debug_message("Setting bandwidth limit to $maxspeed");
			$curl->setopt(CURLOPT_MAX_RECV_SPEED_LARGE, $maxspeed);
		}

		return \$curl;
	}
}

# runs the get or head operations on the user agent
sub libcurl {
	my ($vhost, $uri, $pkfdref) = @_;

	my $url="http://$vhost$uri";
	my $curl = ${&setup_curl};

	my $do_hopping = (exists $pathmap{$vhost});
	my $hostcand;

RETRY_ACTION:
	my $response = new HTTP::Response;

	# make the virtual hosts real. The list is reduced which is not so smart,
	# but since the fetcher process dies anyway it does not matter.
	if ($do_hopping) {
		$hostcand = shift(@{$pathmap{$vhost}});
		debug_message("Candidate: $hostcand");
		$url=($hostcand =~ /^http:/ ? '' : 'http://').$hostcand.$uri;
	}

RETRY_REDIRECT:
	if (!$pkfdref) {
		debug_message ('download agent: setting up for HEAD request');
		$curl->setopt(CURLOPT_NOBODY,1);
	} else {
		debug_message ('download agent: setting up for GET request');
		$curl->setopt(CURLOPT_HTTPGET,1);
		$curl->setopt(CURLOPT_FILE, $$pkfdref);
	}

	push @cache_control, 'Pragma:' if ! grep /^Pragma:/, @cache_control; # Override libcurl default.
	$curl->setopt(CURLOPT_HTTPHEADER, \@cache_control);				
	$curl->setopt(CURLOPT_WRITEHEADER, [\$response, ($pkfdref ? 1 : 0)]);
	$curl->setopt(CURLOPT_URL, $url);

	debug_message("download agent: getting $url");

	if ($curl->perform) { # error
		$response=HTTP::Response->new(502);
		$response->protocol('HTTP/1.1');
		$response->message('pkg-cacher: libcurl error: '.$curl->errbuf);
		info_message("Warning: libcurl failed for $url with ".$curl->errbuf);
		write_header(\$response); # Replace with error header
	}
	$response->request($url);

	if ($response->is_redirect()) {
		# It is a redirect
		info_message('libcurl got redirect for '.$url);

		$url = $response->header("Location");
		info_message('Redirecting to '.$url);
		$response = new HTTP::Response;
		if ($pkfdref) {
			truncate($$pkfdref, 0);
			sysseek($$pkfdref, 0, 0);
		}
		unlink($cached_head, $complete_file);
		goto RETRY_REDIRECT;
	}

	if ($do_hopping) {
		# if okay or the last candidate fails, put it back into the list
		if ($response->is_success || ! @{$pathmap{$vhost}} ) {
			unshift(@{$pathmap{$vhost}}, $hostcand);
		} else {
			# truncate cached_file to remove previous HTTP error
			if ($pkfdref) {
				truncate($$pkfdref, 0);
				sysseek($$pkfdref, 0, 0);
			}
			goto RETRY_ACTION;
		}
	}

	return \$response;
}

sub fetch_store {
	my ($host, $uri) = @_;
	my $response;
	my $pkfd;
	my $filename;

	($filename) = ($uri =~ /\/?([^\/]+)$/);

	my $url = "http://$host$uri";
	debug_message("fetcher: try to fetch $url");

	sysopen(my $pkfd, $cached_file, O_RDWR)
		|| barf("Unable to open $cached_file for writing: $!");

	# jump from the global lock to a lock on the target file
	flock($pkfd, LOCK_EX) || barf('Unable to lock the target file');
	&release_global_lock;

	$response = ${&libcurl($host, $uri, \$pkfd)};	

	flock ($pkfd, LOCK_UN);
	close($pkfd) || warn "Close $cached_file failed, $!";

	debug_message('libcurl returned');

    if ($response->is_success) {
		debug_message("stored $url as $cached_file");

		# assuming here that the filesystem really closes the file and writes
		# it out to disk before creating the complete flag file

		my $sha1sum = `sha1sum $cached_file`;

		if (!$sha1sum) {
			barf("Unable to calculate SHA-1 sum for $cached_file - error = $?");
		}

		($sha1sum) = $sha1sum =~ /([0-9A-Za-z]+) +.*/;

		debug_message("sha1sum $cached_file = $sha1sum");

		&set_global_lock(': link to cache');
		
		if (-f "$cfg->{cache_dir}/cache/$filename.$sha1sum") {
			unlink($cached_file);
			link("$cfg->{cache_dir}/cache/$filename.$sha1sum", $cached_file);
		} else {
			link($cached_file, "$cfg->{cache_dir}/cache/$filename.$sha1sum");
		}

		&release_global_lock;

		debug_message("setting complete flag for $filename");
		# Now create the file to show the pickup is complete, also store the original URL there
		open(MF, ">$complete_file") || die $!;
		print MF $response->request;
		close(MF);
	} elsif(HTTP::Status::is_client_error($response->code)) {
		debug_message('Upstream server returned error '.$response->code." for ".$response->request.". Deleting $cached_file.");
		unlink $cached_file;
	}
	debug_message('fetcher done');
}

1;
