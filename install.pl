#!/usr/bin/perl
#	@(#) setup.pl -- Setup script for apt-cacher.pl
#	$ Revision: $
#	$ Source: $
#	$ Date: $
#
#	Safe to run multiple times; later versions of this script will
#	remove obsolete directories or files and not touch required
#	directories or files.
#

umask 0022;

#############################################################################
### configuration ###########################################################
# Include the library for the config file parser
require '/usr/share/apt-cacher/apt-cacher-lib.pl';

# Read in the config file and set the necessary variables
my $configfile = '/etc/apt-cacher/apt-cacher.conf';

our $cfg;
eval {
        $cfg = read_config($configfile);
};

# not sure what to do if we can't read the config file...
die "Could not read config file: $@" if $@;

my $private_dir = "$cfg->{cache_dir}/private";

################################################
# Check that the cache_dir has been set and continue on (note: this should never happen
# because cache_dir is preset to a default value prior to loading the config file)
die "Warning: config file could not be parsed ($configfile)/ (cache_dir is not set)\n" if ($cfg->{cache_dir} eq '');


@info=getpwnam("www-data");
my @permcmd;
if(-e $cfg->{cache_dir}) {
   @permcmd = ("chown", "--reference", $cfg->{cache_dir});
}
elsif(@info) {
   print "Assuming www-data is the user ID used to run apt-cacher\n";
   @permcmd = ("chown", "$info[2]:$info[3]");
}
else {
   @permcmd = ("/bin/echo", "User account for apt-cacher/http daemon unknown, plese set ownership for the following files manually:");
}

for ("README", "README.txt") {
   my $file=$cfg->{cache_dir}."/$_";
   if (-f $file) {
      print "Found obsolete file $file - removing.\n";
      unlink($file);
   }
}

foreach my $dir ($cfg->{cache_dir}, $cfg->{logdir}, "$cfg->{cache_dir}/private", "$cfg->{cache_dir}/import",
    "$cfg->{cache_dir}/packages", "$cfg->{cache_dir}/headers", "$cfg->{cache_dir}/temp") {
	if (!-d $dir) {
		print "Doing mkdir($dir, 0755)\n";
		mkdir($dir, 0755);
    system (@permcmd, $dir);
	}
	if (!-w $dir) {
		die "Warning, $dir exists but is not is not writable for apt-cacher!\n";
	}
}

# Remove these directories if they exist (obsolete)
foreach my $rmdir ("$cfg->{cache_dir}/tmp", "$cfg->{cache_dir}/head") {
	if (-d $rmdir) {
		print "Doing 'rm -rf $rmdir' (obsolete)\n";
		system("rm -rf $rmdir");
	}
}

# These ownership changes are a cludge: need to make them check httpd.conf for the Apache
# user and set ownership to that, and do it with Perl instead of shell
# EB: fsck that, this may simply overwritte changes by the admin
# `chown -R www-data.www-data $cfg->{cache_dir}`;

# We used to tack a line onto the end of apache.conf. Now we just symlink into conf.d
if(-d "/etc/apache/conf.d" ){
	symlink("/etc/apt-cacher/apache.conf","/etc/apache/conf.d/apt-cacher");
}

if(-d "/etc/apache-ssl/conf.d" ){
	symlink("/etc/apt-cacher/apache.conf","/etc/apache-ssl/conf.d/apt-cacher");
}

if(-d "/etc/apache2/conf.d" ){
	rename("/etc/apache2/conf.d/apt-cacher", "/etc/apache2/conf.d/apt-cacher.conf") || symlink("/etc/apt-cacher/apache.conf","/etc/apache2/conf.d/apt-cacher.conf");
}

# Apache2 needs the cgi module installed, which it isn't by default.
if(-d "/etc/apache2/mods-enabled"){
	symlink("/etc/apache2/mods-available/cgi.load","/etc/apache2/mods-enabled/cgi.load");
}


#vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv
# Just for now we still have to try nuking old entries in httpd.conf,
# because they may have been left behind previously. After a couple
# more releases this should be removed from here and remove.pl

&remove_apache;

# Run database recovery
if ($cfg->{checksum}) {
    require '/usr/share/apt-cacher/apt-cacher-lib-cs.pl';
    &setup_ownership;
    print "Running database recovery...";
    &db_recover;
    print "Done!\n";
}

exit(0);
