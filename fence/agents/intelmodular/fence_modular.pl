#!/usr/bin/perl

# Intel Modular Server fencing based on fence_ibmblade.pl
#
# Tested with an Intel MFSYS25 using firmware package 2.6 Should work with an 
# MFSYS35 as well. 
#
# Requires Net::SNMP
#
# Notes:
#
# The manual and firmware release notes says SNMP is read only. This is not 
# true, as per the MIBs that ship with the firmware you can write to 
# the bladePowerLed oid to control the servers.

use Getopt::Std;
use Net::SNMP; 

# Get the program name from $0 and strip directory names
$_=$0;
s/.*\///;
my $pname = $_;

my $sleep_time = 5; 
my $snmp_timeout = 10;
$opt_o = "reboot";
$opt_u = 161;

# from INTELCORPORATION-MULTI-FLEX-SERVER-BLADES-MIB.my that ships with 
# firmware updates
my $oid_power = ".1.3.6.1.4.1.343.2.19.1.2.10.202.1.1.6";    # bladePowerLed 

# WARNING!! Do not add code bewteen "#BEGIN_VERSION_GENERATION" and
# "#END_VERSION_GENERATION"  It is generated by the Makefile

#BEGIN_VERSION_GENERATION
$RELEASE_VERSION="";
$REDHAT_COPYRIGHT="";
$BUILD_DATE="";
#END_VERSION_GENERATION

sub usage
{
    print "Usage:\n";
    print "\n";
    print "$pname [options]\n";
    print "\n";
    print "Options:\n";
    print "  -a <ip>          IP address or hostname of Intel Modular Server\n";
    print "  -h               usage\n";
    print "  -c <community>   SNMP Community\n";
    print "  -n <num>         Server number to disable\n";
    print "  -o <string>      Action:  Reboot (default), On or Off\n";
    print "  -u <udpport>     UDP port to use (default: 161)\n"; 
    print "  -q               quiet mode\n";
    print "  -t               test power state\n"; 
    print "  -V               version\n";

    exit 0;
}

sub fail_usage
{
  ($msg)= _;
  print STDERR $msg."\n" if $msg;
  print STDERR "Please use '-h' for usage.\n";
  exit 1;
}

sub fail
{
  ($msg) = @_;
  print $msg."\n" unless defined $opt_q;
  $t->close if defined $t;
  exit 1;
}

sub version
{
  print "$pname $RELEASE_VERSION $BUILD_DATE\n";
  print "$REDHAT_COPYRIGHT\n" if ( $REDHAT_COPYRIGHT );

  exit 0;
}

sub get_options_stdin
{
    my $opt;
    my $line = 0;
    while( defined($in = <>) )
    {
        $_ = $in;
        chomp;

	# strip leading and trailing whitespace
        s/^\s*//;
        s/\s*$//;

	# skip comments
        next if /^#/;

        $line+=1;
        $opt=$_;
        next unless $opt;

        ($name,$val)=split /\s*=\s*/, $opt;

        if ( $name eq "" )
        {  
           print STDERR "parse error: illegal name in option $line\n";
           exit 2;
	}
	
        # DO NOTHING -- this field is used by fenced
	elsif ($name eq "agent" ) { } 

        elsif ($name eq "ipaddr" ) 
	{
            $opt_a = $val;
        } 
	elsif ($name eq "community" ) 
	{
            $opt_c = $val;
        } 

        elsif ($name eq "option" )
        {
            $opt_o = $val;
        }
	elsif ($name eq "port" ) 
	{
            $opt_n = $val;
        }
	elsif ($name eq "udpport" )
	{
	    $opt_u = $val; 
	}

        # FIXME should we do more error checking?  
        # Excess name/vals will be eaten for now
	else 
	{
           fail "parse error: unknown option \"$opt\"";
        }
    }
}

# ---------------------------- MAIN --------------------------------

if (@ARGV > 0) {
   getopts("a:hc:n:o:qu:tV") || fail_usage ;

   usage if defined $opt_h;
   version if defined $opt_V;

   fail_usage "Unknown parameter." if (@ARGV > 0);

   fail_usage "No '-a' flag specified." unless defined $opt_a;
   fail_usage "No '-n' flag specified." unless defined $opt_n;
   fail_usage "No '-c' flag specified." unless defined $opt_c;
   fail_usage "Unrecognised action '$opt_o' for '-o' flag"
      unless $opt_o =~ /^(reboot|on|off)$/i;

} else {
   get_options_stdin();

   fail "failed: no IP address" unless defined $opt_a;
   fail "failed: no server number" unless defined $opt_n;
   fail "failed: no SNMP community" unless defined $opt_c;
   fail "failed: unrecognised action: $opt_o"
      unless $opt_o =~ /^(reboot|on|off)$/i;
}

my ($snmpsess, $error) = Net::SNMP->session ( 
	-hostname   => $opt_a, 
	-version    => "snmpv1", 
	-port       => $opt_u, 
	-community  => $opt_c,
	-timeout    => $snmp_timeout); 

if (!defined ($snmpsess)) { 
	printf("$RELEASE_VERSION ERROR: %s.\n", $error);
	exit 1; 
};

# first check in what state are we now
my $oid = $oid_power . "." . $opt_n;
my $oid_val = ""; 
my $result = $snmpsess->get_request ( 
	-varbindlist => [$oid]
);
if (!defined($result)) {
	printf("$RELEASE_VERSION ERROR: %s.\n", $snmpsess->error);
	$snmpsess->close;
	exit 1;
}

if (defined ($opt_t)) { 
	printf ("$RELEASE_VERSION STATE: Server %d on %s returned %d\n", $opt_n, $opt_a, $result->{$oid}); 
	exit 1; 
};

if ($opt_o =~ /^(reboot|off)$/i) { 
	if ($result->{$oid} == "0") { 
		printf ("$RELEASE_VERSION WARNING: Server %d on %s already down.\n", $opt_n, $opt_a); 
		$snmpsess->close; 
		exit 0; 
	}; 
} else { 
	if ($result->{$oid} == "2") { 
		printf ("$RELEASE_VERSION WARNING: Server %d on %s already up.\n", $opt_n, $opt_a); 
		$snmpsess->close; 
		exit 0; 
	};
};

# excellent, now change the state 
if ($opt_o =~ /^reboot$/i) { 
	# reboot
	$oid_val = "4"; 
} elsif ($opt_o =~ /^on$/i) { 
	# power on
	$oid_val = "2"; 
} else { 
	# power down
	$oid_val = "3"; 
};

$result = $snmpsess->set_request (
	-varbindlist => [$oid, INTEGER, $oid_val]
); 

if (!defined ($result)) { 
	printf("$RELEASE_VERSION ERROR: %s.\n", $snmpsess->error);
	$snmpsess->close;
	exit 1;
}; 

# now, wait a bit and see if we have done it
sleep($sleep_time); 

undef $result; 
$result = $snmpsess->get_request ( 
	-varbindlist => [$oid]
);

if (!defined($result)) {
	# this is a real error
	printf("$RELEASE_VERSION ERROR: %s.\n", $snmpsess->error);
	$snmpsess->close;
	exit 1;
}; 

if ($opt_o =~ /^(off)$/i) { 
	if ($result->{$oid} == "2") { 
		printf ("$RELEASE_VERSION ERROR: Server %d on %s still up.\n", $opt_n, $opt_a); 
		$snmpsess->close; 
		exit 1; 
	}; 
} else { 
	if ($result->{$oid} == "0") { 
		printf ("$RELEASE_VERSION ERROR: Server %d on %s still down.\n", $opt_n, $opt_a); 
		$snmpsess->close; 
		exit 1; 
	};
};

# everything's a ok :) 
$snmpsess->close; 

printf ("$RELEASE_VERSION SUCCESS: Server %d on %s changed state to %s\n", $opt_n, $opt_a, $opt_o) unless defined $opt_q;
exit 0; 

