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

package TenBees::DiskQueue;
use warnings;
use strict;

use Tie::File;
use Fcntl qw/:flock /;

use TenBees::Config;
use TenBees::Logger;
use TenBees::Agent;
use MIME::Base64 qw/ encode_base64 decode_base64 /;

our @_queue; # queue array
our $_q; # queue handle

our %_errors;


sub get_errors {
    return %_errors; # return copy, not ref to prevent external modification
}


sub report_errors {
    
    my $config = TenBees::Config->get();
    
    if ($_errors{DataAccess}) {
        ERROR "Problems accessing $$config{DiskQueueFile}: $_errors{DataAccess}";
        $_errors{DataAccess} = '';
    }
    
    if ($_errors{DataFormat}) {
        ERROR "Problems with data format. Remove or check $$config{DiskQueueFile}";
        $_errors{DataFormat} = '';
    }
    
}


sub pack_record {
    
    my $record = shift;
    my $config = TenBees::Config->get();
    my $eol = $config->{DiskQueueEOL};
    die "disk queue EOL is not set" if !defined $eol;
    return encode_base64($record, $eol);
    
}


sub unpack_record {
    
    my $record = shift;
    return decode_base64($record);
    
}

# return 1 if lock successful, 0 - otherwise
sub lock_queue {

    my $config = TenBees::Config->get();

    my $attempts = $config->{DiskQueueLockAttempts};
    my $timeout = $config->{DiskQueueLockTimeout};

    do {
    
        DEBUG "Trying to lock disk queue file. Attempts left: $attempts" if DEBUG_MODE;
    
        $attempts--;
    
        my $res = $_q->flock(LOCK_EX|LOCK_NB);
    
        if($res == 1) {
            DEBUG "queue successfully locked" if DEBUG_MODE;
            return 1;
        }
    
        DEBUG "Failed to lock disk queue: $!" if DEBUG_MODE;
    
        if($attempts > 0) {
            DEBUG "Waiting for $timeout seconds till next attempt" if DEBUG_MODE;
            sleep $timeout;
        }

    } while($attempts);

    return 0;
}


sub unlock_queue {
    my $unlock_result = $_q->flock(LOCK_UN);
    DEBUG "Unlocking disk queue file exit code: $unlock_result" if DEBUG_MODE;
    ERROR "Failed to unlock the queue ($unlock_result): $!" if !$unlock_result;
    
}


sub get_length {
    my $length = undef; 
    $length = scalar(@_queue);
    $length;
}


sub is_empty {
    return get_length() == 0;
}


sub initialize {
    my $config = TenBees::Config->get();

    $_errors{DataAccess} = '';
    $_errors{DataFormat} = '';

    DEBUG "Initializing DiskQueue" if DEBUG_MODE;

    $_q = tie (@_queue, 'Tie::File', $config->{DiskQueueFile}) or do {
        $_errors{DataAccess} = $!;
        die "Can't tie $$config{DiskQueueFile}";
    };

    if(lock_queue() == 0) {
        $_errors{DataAccess} = $!;
        ERROR("Can't lock $$config{DiskQueueFile} - there is probably another agent is running.");
    }

    DEBUG "Queue size is: " . get_length() if DEBUG_MODE;
}


# returns number of elements read or -1 on error
sub read_all {
    
    my $self = shift;
    my $target = shift;
    
    if(!defined($target)) {
        ERROR "Requested to read all elements, but no target array provided.";
        return -1;
    }
    
    my $config = TenBees::Config->get();
    my $size = undef;
    $size = scalar(@_queue);
    my @backup = ();
    
    while(scalar(@_queue)){
        my $t = shift @_queue;
        push @backup, $t;
        $t = unpack_record($t);
        push @$target, $t;
    }
    
    @_queue = @backup;
    return $size;
}


# remove first N elems
sub remove_elems {
    
    my $self = shift;
    my $n = shift;
    
    DEBUG "Requested removal of $n elements" if DEBUG_MODE;
    
    if(!defined($n) || ($n < 0)) {
        ERROR "Provided invalid number of elements to be removed.";
        return;
    }
    
    my $size = undef;
    splice @_queue, 0, $n;
    $size = scalar(@_queue);
    
    DEBUG "Removed $n elements succesfully, new queue size is $size" if DEBUG_MODE;
}


sub save_record {
    
    my $self = shift;
    my $record = shift;
    
    DEBUG "Disk queue record save requested" if DEBUG_MODE;

    if(!$record) {
        WARN "Requested to save the record, but no record provided, skipping.";
        return;
    }

    my $config = TenBees::Config->get();

    my $length = get_length();
    DEBUG "Current queue length is $length" if DEBUG_MODE;
    
    if ($length >= $config->{DiskQueueMaxSize}) {
        ERROR "Disk queue has reached maximum size (".$config->{DiskQueueMaxSize}." records). Current data packet was lost.";
        return;
    }

    INFO "Saving commit to the disk queue";

    my $res = undef;
    my $packed_record = pack_record($record);
    
    $res = push @_queue, ($packed_record);
    DEBUG "Result of push: $res" if DEBUG_MODE;
    DEBUG "Queue size is: " . get_length() if DEBUG_MODE;
}


sub uninitialize {
    
    unlock_queue();
    $_q = undef;
    untie @_queue;
    
}


sub cleanup {
    
    my $config = TenBees::Config->get();
    
    if(-e $config->{DiskQueueFile}) {
        unlink $config->{DiskQueueFile} 
            or die "Failed to unlink disk queue file: $!";
    }
}

1;
