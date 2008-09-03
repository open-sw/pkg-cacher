#!/usr/bin/perl -w

# Restart Apache to make it read its modified config file
if( -f "/etc/init.d/apache" ) {
	print "1\n";
	#`/etc/init.d/apache restart`;
} elsif( -f "/etc/init.d/apache-ssl" ) {
	print "2\n";
	#`/etc/init.d/apache-ssl restart`;
} else {
	print "Expected Apache init script was not found. Please restart Apache manually.\n";
}

exit(0);
