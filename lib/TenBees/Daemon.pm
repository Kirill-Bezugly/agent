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

package TenBees::Daemon;
use warnings;
use strict;

use POSIX qw/ :signal_h :sys_wait_h :errno_h /;
use Cwd qw/ chdir /;
use FindBin qw/ $Bin /;
use Errno;

use TenBees::Config;
use TenBees::Logger;
use TenBees::Agent;
use TenBees::Utils qw/ set_sid close_files enable_echo /;

our %state;

sub start {
    
    my $config = TenBees::Config->get();
  
    DEBUG "About to fork() the monitoring daemon." if DEBUG_MODE;
    my $kidpid = fork();

    if (!defined($kidpid)) {
        
        DEBUG "fork() failed to create / return children's PID." if DEBUG_MODE;
        
        my $message = "Fork failed: $!";
        print $message;
        CRITICAL $message;
    
        return 0;

    } elsif ($kidpid) {
        return 1; #Nothing to do for the parent

    } else {

        DEBUG "Monitoring daemon fork() successfull." if DEBUG_MODE;
        INFO "10bees agent monitoring for host id $config->{HostId} started." ;
        
        $SIG{INT} = $SIG{TERM} = \&sigint_handler;
        
        DEBUG "Switching to the appropriate user." if DEBUG_MODE;
        set_sid();       
        
        DEBUG "About to save process pid ($$) to the $config->{Pid}." if DEBUG_MODE;
        
        open(my $PID, '>'.$config->{Pid}) or die "Can't open PID file ($$ >$config->{Pid}): $!";
        print $PID $$;
        close $PID or die "Can't close PID file ($$ >$config->{Pid}): $!";
        
        DEBUG "PID saved successfully." if DEBUG_MODE;
        
        DEBUG "Disabling output buffering" if DEBUG_MODE;
        $| = 1;
        
        DEBUG "Changing working directory to $Bin" if DEBUG_MODE;
        chdir $Bin or die "Can't chdir($Bin): $!";
        
        DEBUG "Starting main daemon cycle." if DEBUG_MODE;
        
        $0 = $config->{ProcTitle};
        TenBees::Agent->run();

    }
}


sub stop {
    
    DEBUG "Agent's stop requested." if DEBUG_MODE;
    
    my $config = TenBees::Config->get();

    DEBUG "Reading agent's PID from the file ($config->{Pid})." if DEBUG_MODE;
    
    if (!-e $config->{Pid}) {
        DEBUG "Can't find PID file $config->{Pid}, agent, probably, wasn't running." if DEBUG_MODE;
        return 0;
    }
    
    open(PID, $config->{Pid}) or die "Can't open PID file $config->{Pid} for reading: $!";
    my $pid = <PID>;
    close PID;

    DEBUG "Got agent's PID: $pid" if DEBUG_MODE;
    
    unless ($pid) {
        WARN "Can't stop the agent: failed to get process id from $config->{Pid}.";
        return;
    }

    $pid =~ s/[^\d]//gs;

    DEBUG "About to send INT 'kill' to $pid..." if DEBUG_MODE;
    INFO "Stopping monitoring agent's process (pid=$pid)...";

    unless (kill INT => $pid) {
        die "Can't kill process $pid" . ($! ? ": $!": '');
    }

    sleep 1;

    if (-e $config->{Pid}) {
        unlink $config->{Pid} or die "Failed to remove PID file ($config->{Pid}): $!";
        DEBUG "PID file removed." if DEBUG_MODE;
    } else {
        DEBUG "PID file not found." if DEBUG_MODE;
    }

    DEBUG "Monitoring agent stopped." if DEBUG_MODE;
    
    return 1;
}


sub is_running {

    DEBUG 'Requested verification for the process state.' if DEBUG_MODE;

    my $config = TenBees::Config->get();
    
    #pidfile doesn't exist
    if (!-f $config->{Pid}) {
        DEBUG "Agent's PID file $config->{Pid} was not found." if DEBUG_MODE;
        return 0;
    }
        
    #is empty
    if (-z $config->{Pid}) {
        DEBUG "Agent's PID file $config->{Pid} is empty" if DEBUG_MODE;
        return undef;
    }

    DEBUG "Agent's PID file $config->{Pid} is on place, non-zero size, trying to read it..." if DEBUG_MODE;
        
    open(PID, "$config->{Pid}")
        or die("Can't open PID file $config->{Pid}!: $!");

    chomp(my $pid = <PID>);
    $pid =~ s/[^\d]//gs;

    close PID;

    DEBUG "Read PID file successfully: $pid, about to check it." if DEBUG_MODE;
    
    die "Agent's PID file $config->{Pid} doesn't contain a proper PID!"
        if (!$pid);

    if ((kill 0, $pid) || $!{EPERM}) {
        DEBUG "$pid process verified Ok." if DEBUG_MODE;
        return $pid;
        
    } elsif ($!{ESRCH}) {
        DEBUG "$pid process verification failed" if DEBUG_MODE;
        return 0;
    
    } else {
        DEBUG "Unexpected errno result for checking process $pid status: $!" if DEBUG_MODE;
        return undef;
    }
    
    return -1; #shouldn't be there.
}


sub sigint_handler {

    DEBUG "Recovering terminal echo inside signal handler." if DEBUG_MODE;
    WARN "Fail to recover terminal echo" if (0 != enable_echo(1));

    my $config = TenBees::Config->get();
    
    #Verify & clean-up PID file in daemonized children, if the file is still there.
    DEBUG "PID $config->{Pid} file found, while agent shutting down - trying to delete it." if DEBUG_MODE;
    unlink $config->{Pid};

    INFO "Handling terminating signal, leaving properly.";
    
    exit 0;
}

1;
