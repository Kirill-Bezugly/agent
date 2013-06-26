#!/usr/bin/env perl

# =================================================================================== #
#  10bees system monitoring agent
#  Copyright 2011-2013
#
#  You may use it for the monitoring purposes of your computer with 10bees.com service.
#  Code can't be redistributed, or used for any other purposes, unless
#  written permission granted from the copyright owner.
#
#  http://10bees.com/support/
# =================================================================================== #

use warnings;
use strict;
use FindBin qw/ $Bin /;
use lib "$Bin/lib/";

#Catch & dump Perl level error
BEGIN { $SIG{__DIE__} = sub {
        return if $^S; # it's OK to fail inside eval block
        open (FATALLOG, ">$Bin/FatalError.dump");
        print FATALLOG "Service failed: $_[0]\n";
        close (FATALLOG);
    }
}

use Win32;
use Win32::Daemon;

use TenBees::Config;
use TenBees::Logger;
use TenBees::Agent;
use TenBees::Register qw/ register host_registered/;

my $DEFAULT_LOG_FILE = "$Bin\\agent.log";
my $iterations_count = 60; #agent's self-restart after this counter
my $sleep_before_restart = 30; #~5 seconds to collect the data, 5 second to wait until the new service starts, ~5 seconds to let it start

my $config = TenBees::Config->get();

if(!Win32::IsAdminUser()) {
    die "Windows requires monitoring tool to be executed with Administrative privileges - please, restart it appropriately."
}

sub enable_disk_io_performance {
	DEBUG "Executing proc_sysinfo's required diskperf..." if DEBUG_MODE;
	system ('diskperf -y >NUL');
}

my $command = shift @ARGV || '';

if (!$command) { #non-interactive (service) run
	$config->{LogFile} = $DEFAULT_LOG_FILE if !$config->{LogFile};
	TenBees::Logger::initialize($config);
	
} elsif ($command eq 'register') {
	enable_disk_io_performance();
    do_register();
	
} elsif ($command eq 'check_registration') {
    do_check_registration();
	
} elsif ($command eq 'version') {
    do_print_version();
	
} elsif ($command eq 'cleanup') {
    do_cleanup();
	
} else {
	
	print join "\n",
		"usage: agent (register|start|stop|restart|cleanup|version|show-collected-data)",
		'',
		'register             - register agent',
		'start                - start agent',
		'stop                 - stop agent',
		'restart              - restart agent',
		'cleanup              - clean up disk queue',
		'version              - show version',
		'show-collected-data  - display collected system information',
		'';
	  
	exit 0;
}

#Registering start/stop Win32::Daemon handlers
Win32::Daemon::RegisterCallbacks({
        start       =>  \&Callback_Start,
        running     =>  \&Callback_Running,
        stop        =>  \&Callback_Stop,
        pause       =>  \&Callback_Pause,
        continue    =>  \&Callback_Continue,
});

my %Context = (
    last_state => SERVICE_STOPPED,
    start_time => time(),
);

$| = 0; # disable buffering

Win32::Daemon::StartService(\%Context, 20000);


#Service init code
sub Callback_Start {
    my($Event, $Context) = @_;

    my $config = TenBees::Config->get();
    $config->{LogFile} = $DEFAULT_LOG_FILE if !$config->{LogFile};
	
	if (!host_registered()) {
        INFO "Agent is not registered - please run '$Bin/agent.cmd register' to fix this.";
		exit 0;
	}
	
    TenBees::Logger::initialize($config);
    INFO "10bees agent v. $config->{Version} init complete";
	
	enable_disk_io_performance();

    TenBees::Agent->collect_and_send();

    $Context->{last_state} = SERVICE_RUNNING;
    Win32::Daemon::State(SERVICE_RUNNING);
}


sub restart_and_exit {
    my $Context = shift;

    INFO "Maximum number of iterations was reached, going to sleep($sleep_before_restart) and then restart...";

	sleep($sleep_before_restart);
	
    $Context->{last_state} = SERVICE_STOPPED;
    Win32::Daemon::State(SERVICE_STOPPED);

    DEBUG "Sleeping for 5 secs" if DEBUG_MODE;
    sleep 5;

    DEBUG "Starting '10bees monitoring' service (net start)" if DEBUG_MODE;

    my $rv = system('net start "10bees monitoring"');
    if ($rv) {
        ERROR "Error while starting service. Error code: $rv";
        exit 1;
    }
    exit;
}

#Service running code
sub Callback_Running {
    my($Event, $Context) = @_;

    my $config = TenBees::Config->get();

    while (1) {
        for (1..$config->{SleepTime} / 5) {
            return unless SERVICE_RUNNING == Win32::Daemon::State();
            sleep 5;
        }

        DEBUG "Windows iteration counter = $iterations_count, collecting and sending the data..." if DEBUG_MODE;
        TenBees::Agent->collect_and_send();
		$iterations_count--;
        restart_and_exit($Context) if ($iterations_count < 0);
    }
}    


sub Callback_Stop {
    my($Event, $Context) = @_;

    INFO "10bees-agent is stopping..." if DEBUG_MODE;

    $Context->{last_state} = SERVICE_STOPPED;
    Win32::Daemon::State(SERVICE_STOPPED);

    Win32::Daemon::StopService();
}


#Stub for pause and continue - not supported.
sub Callback_Pause {
    my($Event, $Context) = @_;
    $Context->{last_state} = SERVICE_PAUSED;
    Win32::Daemon::State(SERVICE_PAUSED);
}


sub Callback_Continue {
    my($Event, $Context) = @_;
    $Context->{last_state} = SERVICE_RUNNING;
    Win32::Daemon::State(SERVICE_RUNNING);
}


sub do_register {

    INFO 'Registering client...';

    my $cred_file = shift @ARGV;

    # if cred_file is undef interactive mode will be launched automatically
    my $regResult = register($cred_file);

    if (1 == $regResult) {
        exit 0; #success
		
    } elsif (0 == $regResult) {
        exit 1; #error
		
	} elsif (255 == $regResult) {
		INFO "Registration requested for the already registered agent, skipping...";
		exit 0;
		
    } else {
        ERROR "Unexpected result of registration procedure: $regResult";
        ERROR "Please restart in debug mode and retry.";
        exit -1;
    }
}


sub do_check_registration {

    DEBUG "Agent's check for registration requested - calling appropriate functions now." if DEBUG_MODE;
    
    my $config = TenBees::Config->get();
    my $res = !host_registered();
	
    if($res) {
        INFO "Agent is not registered";
    } else {
        INFO "Agent is already registered";
    }
	
    exit $res;
}


sub do_print_version {
	
    DEBUG "Agent's version requested - calling appropriate functions now." if DEBUG_MODE;

    my $config = TenBees::Config->get();
    die "Agent version not defined in config" if(!defined $config->{Version});

    print '10bees.com monitoring agent, version ' . $config->{Version} . "\n";

    exit 0;
}


sub do_cleanup {
	
    DEBUG "Agent's disk queue cleanup requested - calling appropriate functions now." if DEBUG_MODE;
    
    TenBees::DiskQueue->cleanup(); # will die on error
    
    INFO "Disk queue cleanup completed successfully.";
    
    exit 0;
}

# vim:ff=dos