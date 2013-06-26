use strict;
use warnings;

use FindBin qw/ $Bin /;
use lib "$Bin/../lib";
use lib "$Bin/";

use TenBees::Config;
use TenBees::Logger;
use TenBees::ProcSysInfo qw/ get_sysinfo /;

use POSIX;
use Test::More;

use constant MAX_SYSINFO_GET_TIME => 2;

if ($^O eq 'MSWin32') {
   plan skip_all => "not implemented for Win32 yet";
   
} else {
    no strict;
    plan no_plan;
}

my $CHILD = undef;

my $was_killed = 0;

my $config = TenBees::Config->get();
TenBees::Logger::initialize($config);

my $data = '';

sub kill_child {
   kill(9, $CHILD);
   $was_killed = 1;
};

#
# Verify if proc_sysinfo could be started successfully at all.
#
sub child_sub {
    eval {
        TenBees::ProcSysInfo::get_check_process('force'); # try to restart sysinfo
        get_sysinfo(\$data);
    };
    exit 1 if $@;
    exit 0; 
}

my $start = time();
$CHILD = fork();

#
# Verify how much time is required to get a sysinfo (no more than 10 seconds)
#
if($CHILD == 0) { #child
    child_sub();
    
} elsif($CHILD > 0) { #parent
   
    $SIG{ALRM} = \&kill_child;
    alarm 10;
    waitpid($CHILD, 0);
    my $end = time();
    my $ret = WEXITSTATUS(${^CHILD_ERROR_NATIVE});
    
    $SIG{ALRM} = "IGNORE";
    ok(!$was_killed, "children Ok");
    
    my $elapsed = $end - $start;
    ok($elapsed <= MAX_SYSINFO_GET_TIME, "got sysinfo data in expected time window " . MAX_SYSINFO_GET_TIME . " (elapsed: $elapsed)");
    
    $was_killed = 0;
    #ok($ret == 0, "sysinfo returned from the running module (ret: $ret)"); #can not be tested with SIG{'CHILD'}=IGNORE
    
}

#
# Verify if agent handles missing binary correctly
#
my $binary = join '/', ($config->{HomeDir}, $config->{ProcSysInfoDir} , TenBees::ProcSysInfo::binary_name());

rename $binary, "${binary}.1";
$CHILD = fork();

if($CHILD == 0) { #child
    child_sub();
    
} elsif($CHILD > 0) { #parent
   
   my $perl_version = sprintf "%vd", $^V;
   
    $SIG{ALRM} = \&kill_child;
    
    alarm 10;
    waitpid($CHILD, 0);
    
    $SIG{ALRM} = "IGNORE";
    ok(!$was_killed, "Handled non-existent sysinfo binary case without an agent failure (was_killed = $was_killed)");
    
    $was_killed = 0;
}

rename "${binary}.1", $binary;