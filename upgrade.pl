#!/usr/bin/perl -w
#	@(#) remove.pl -- Upgrade script for apt-cacher
#	$ Revision: $
#	$ Source: $
#	$ Date: $
# This script is actually almost identical to the remove script, except that
# on upgrade we don't want to nuke the cache contents so that part is commented
# out. We also don't want to restart Apache twice (it already gets done by the
# install script that gets run at the end of the upgrade, and even that's not
# necessary).

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
&remove_apache;

## Delete the cache directory and everything in it
#system("rm -rf $config{cache_dir}");
#
## Delete the two log files (leaving the directory behind for now)
#unlink($config{logfile});
#unlink($config{errorfile});
#unlink($config{reportfile});

exit(0);
