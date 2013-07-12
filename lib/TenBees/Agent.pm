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

package TenBees::Agent;
use warnings;
use strict;

use base 'Exporter';
our @EXPORT_OK = qw/ send_records /;

use Data::MessagePack;
use TenBees::Config;
use TenBees::Logger;
use TenBees::Delivery qw/ send2collector /;
use TenBees::DiskQueue;
use TenBees::ProcSysInfo qw/ get_sysinfo ping_sysinfo /;
use TenBees::Dispatcher qw/ get_dispatcher_data /;
use POSIX qw/:sys_wait_h /;


#Wrapper here to avoid disclosing functions work.
sub collect_and_send {
    
    my $sysinfo = '';
    
    DEBUG 'Entering collect and send function' if DEBUG_MODE;
    
    eval {
        get_sysinfo(\$sysinfo);
    };
    if($@) {
        CRITICAL "Failed to get sysinfo: $@";
    }
    
    eval {
        send_or_save(\$sysinfo, get_dispatcher_data());
    };
    if($@) {
        CRITICAL "Cache enabled message delivery has failed: $@.";
    }
}


#Takes one argument: already packed record
#gets all records from queue if any
#and tries to send them along with new one
#if ok empties queue and returns 0
#otherwise returns 1
sub deliver_or_save_to_cache {

    my $new_record = shift;
    DEBUG "$$ started" if DEBUG_MODE;

    my @records = ($new_record);
    my $nrecords = 1; # at first there is only new record

    DEBUG "Initializing disk queue cache." if DEBUG_MODE;
    eval {
        TenBees::DiskQueue->initialize();
    };

    if($@) {
        CRITICAL "Failed to initialize disk queue - errors to follow";
        TenBees::DiskQueue->report_errors();
        return 1;
    }

    DEBUG "Trying to get records from queue" if DEBUG_MODE;
    my $n_from_queue = TenBees::DiskQueue->read_all(\@records);
    DEBUG "read_all() returned $n_from_queue" if DEBUG_MODE;

    $nrecords += $n_from_queue if ($n_from_queue > 0);

    DEBUG "Trying to send $nrecords message(s)" if DEBUG_MODE;

    my $delivery_code = send_records(\@records, $nrecords);
    
    if($delivery_code == 200) {

        DEBUG "$nrecords records were sent successfully." if DEBUG_MODE;

        if($n_from_queue > 0) {
            TenBees::DiskQueue->remove_elems($n_from_queue);
            INFO "$n_from_queue message(s) sent successfully to the server from the queue.";
        }

        DEBUG "Data delivered successfully to the server ($nrecords)." if DEBUG_MODE;
    
    } elsif(($delivery_code == 400) || ($delivery_code == 403) || ($delivery_code == 500)) {
    
        DEBUG "$nrecords records were rejected by the server." if DEBUG_MODE;

        if($n_from_queue > 0) {
            TenBees::DiskQueue->remove_elems($n_from_queue);
            INFO "$n_from_queue rejected message(s) removed from the queue.";
        }

        DEBUG "$nrecords rejected by the server and removed from the queue." if DEBUG_MODE;
    
    } elsif($delivery_code == 404) {

        DEBUG "Deliver code: $delivery_code, failed to deliver $nrecords message(s). Trying to save the last one to the disk queue" if DEBUG_MODE;

        eval {
            TenBees::DiskQueue->save_record($new_record);
        };

        if($@) {
            ERROR "Failed to save record to the queue";
            TenBees::DiskQueue->report_errors();
            TenBees::DiskQueue->uninitialize();
            return 1;
        }

    } else {

        $delivery_code = '<empty>' if (!defined($delivery_code));
        WARN "Unknown delivery code: $delivery_code.";
        
    }

    TenBees::DiskQueue->uninitialize();
    return 0;
}


sub send_or_save {

    my ($sysinfo_data_ref, $dispatcher_data) = @_;

    my $config = TenBees::Config->get();

    if (!$$sysinfo_data_ref) {
        ERROR "Requested the delivery of the empty sysinfo - not communicating to the collector.";
        return 1;
    }

    if (!$dispatcher_data) {
        DEBUG "Got sysinfo data to be delivered to the server." if DEBUG_MODE;

    } elsif ($dispatcher_data) {
        DEBUG "Got sysinfo & dispatcher data to be delivered to the server." if DEBUG_MODE;
    }

    my $agent_data_msgpack = Data::MessagePack->pack({
            agent_version => $config->{Version},
    });

    my $packed_new_record = $agent_data_msgpack.$$sysinfo_data_ref.$dispatcher_data;

    DEBUG "Starting separated child process to send the data to the collector" if DEBUG_MODE;
    my $pid = fork();

    if (!defined($pid)) {
        ERROR "Failed to fork() data sending children. Error: '$!', OS extended error: '$^E', child error: '$?'.";
        return 0;
    }
    
    DEBUG "Separated child process pid: $pid (SIG{CHLD}=$SIG{'CHLD'})" if (DEBUG_MODE && defined($pid));
    
    if ($pid == 0) { # child

        my $deliver_exit_code = deliver_or_save_to_cache($packed_new_record);
        DEBUG "Forked data delivery return and exit code: $deliver_exit_code" if DEBUG_MODE;
        exit($deliver_exit_code);
    
    } elsif (defined $pid) { # verifying clean children recycling

        #On MacOS X 10.6 and 10.7 manual waitpid() is still the best way to go
        DEBUG "Parent agent verifying clean PID=$pid children recycling..." if DEBUG_MODE;
        my $kid = waitpid($pid, 0);
        DEBUG "Parent agent's waitpid()=$kid" if DEBUG_MODE;
        
    }

    return 1;
}


sub send_records {

    my ($records, $n) = @_;
    DEBUG 'Sending data to the server...' if DEBUG_MODE;

    my $package = join('', @$records);
    my $response = send2collector('put', \$package, { count => $n });

    DEBUG "Server response: $response->[0]" if DEBUG_MODE;

    my $server_responce_code = undef;
    
    if ($response->[0]) {    
        ($server_responce_code) = $response->[0] =~ m|^HTTP/1.1 (\d+).*|;
        DEBUG "Have got the server reply $server_responce_code." if DEBUG_MODE;
        
    } elsif (!defined($response->[0])) {
        $response->[0] = '';
        DEBUG "Server reply is blank." if DEBUG_MODE;
    }

    if ($server_responce_code != 200) {
        WARN "Failed to send statistics data - server code=$server_responce_code, server responce: $response->[0]";
    }
    
    return $server_responce_code;
}


# Call it in case if something goes completely wrong
sub critical_error {
    my $message = shift || '';
    my @execution_stack = Utils::get_execution_stack();
    
    my $error_message = "A critical error raised";
    
    if ($message) {
	$error_message .= ": $message" ;
    } else {
	$error_message .= " at:\n";
	$error_message .= join ("\n", @execution_stack);
    }
    
    ERROR $error_message;
    exit 255;
}


sub run {

    my $config = TenBees::Config->get();

    die "Agent can not be started, unless the server is registered. Please, execute it with 'register' option."
      if (!defined( $config->{HostId}) && !defined($config->{AuthKey}));

    DEBUG "Starts collect_and_send() cycle." if DEBUG_MODE;
    while (1) {

        my $sleep_time = $config->{SleepTime};
        my $start_time = time();

        if (DEBUG_MODE) {
            my ($vsize, $rss) = TenBees::Utils::get_memory_used_by_agent();
            DEBUG "Agent's memory usage usage: vsize: $vsize, rss: $rss" if (defined $vsize && defined $rss);
        }

        DEBUG "Requesting data to be collected and send" if DEBUG_MODE;
        collect_and_send();

        $sleep_time -= time() - $start_time;

        next if $sleep_time < 0;

        DEBUG "Sleeping for ".($sleep_time / 2)." seconds" if DEBUG_MODE;
        sleep $sleep_time / 2;

        ping_sysinfo();
        DEBUG "ping_sysinfo() Ok" if DEBUG_MODE;

        $sleep_time -= time() - $start_time;
        next if $sleep_time < 0;

        DEBUG "Sleeping for $sleep_time seconds" if DEBUG_MODE;
        sleep $sleep_time;
    }

    return 1;
}

1;
