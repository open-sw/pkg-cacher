#!/usr/bin/perl -w
#	@(#) remove.pl -- Remove script for apt-cacher
#	$ Revision: $
#	$ Source: $
#	$ Date: $
#

my $path = $ENV{PATH_INFO};
#############################################################################
### configuration ###########################################################
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

################################################

# Now set some things from the config file
$config{reportfile} = "$config{logdir}/report.html";



# Remove the include lines from Apache's httpd.conf
# Thankfully this is a lot easier now we're just symlinking our config file!
if(-d "/etc/apache/conf.d/" ){
	unlink("/etc/apache/conf.d/apt-cacher");
}

if(-d "/etc/apache-ssl/conf.d/" ){
	unlink("/etc/apache-ssl/conf.d/apt-cacher");
}

if(-d "/etc/apache2/conf.d/" ){
	unlink("/etc/apache2/conf.d/apt-cacher");
	unlink("/etc/apache2/conf.d/apt-cacher.conf");
}


# Delete the cache directory and everything in it, in the purge step
#system("rm", "-rf", $config{cache_dir});

# Delete the two log files (leaving the directory behind for now)
unlink($config{logfile});
unlink($config{errorfile});
unlink($config{reportfile});

#vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv
# Just for now we still have to try nuking old entries in httpd.conf,
# because they may have been left behind previously. After a couple
# more releases this should be removed from here and install.pl

# Remove the include lines from Apache's httpd.conf

&remove_apache;

exit(0);
