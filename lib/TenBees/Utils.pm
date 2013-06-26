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

package TenBees::Utils;
use warnings;
use strict;

our @EXPORT_OK = qw/ daemonize set_gid_uid set_sid 
                     close_files enable_echo dump_binary_data
                     is_printable touch_file get_execution_stack /; 

use base 'Exporter';
use TenBees::Config;
use TenBees::Logger;


#Detach process from terminal and make all preparations for running in background 
sub daemonize {

    if($^O eq 'MSWin32') {
        WARN "On Windows agent runs as a service, no daemonizing here.";
        return;
    }
    
    my $config = TenBees::Config->get();

    DEBUG "Daemonizing the agent, logger's output set to syslog." if DEBUG_MODE;
    TenBees::Logger::set_backend($config, 'Syslog');
    
    $SIG{HUP}  = 'IGNORE';

    my $pid = fork();

    if ($pid < 0) {
        die "Failed to fork: $!";
    }

    if ($pid) {
        DEBUG "Forked, leaving parent's process." if DEBUG_MODE;
        exit 0;
    }

    set_sid();

    DEBUG "Clearing file creation mask." if DEBUG_MODE;
    umask 0;

    DEBUG "Closing all opened file descriptors." if DEBUG_MODE;
    close_files();
    
    #Avoid spamming syslog with debug messages
    if (DEBUG_MODE) {
        DEBUG "Agent is running in debug mode, logging is redirected to the local file.";
        TenBees::Logger::set_backend($config, 'File');
    }

    if (-e '/dev/null') {
        DEBUG "Reopening STDIN & STDOUT to '/dev/null'." if DEBUG_MODE;
        open STDIN, '/dev/null';
        open STDOUT, '>>/dev/null';
        #STDERR is caught by Tie::STDERR (see TenBees::Logger)
        
    } else {
        DEBUG "Closing STDIN & STDOUT." if DEBUG_MODE;
        close STDIN;
        close STDOUT;
    }
    
}


sub set_gid_uid {

    my $config = TenBees::Config->get();

    my $cuid = POSIX::getuid(); # Current UID

    my $uid = POSIX::getpwnam($config->{User});    
    die("System user ($config->{User}) not found!") if !defined $uid;

    my $cgid = POSIX::getgid();
    my $gid = POSIX::getgrnam($config->{Group});
    die("System group ($config->{Group}) not found!") if !defined $gid;

    if (($uid == $cuid) && ($gid == $cgid)) {
        return 1;
    }

    # Changing GID first, otherwise root permissions will be lost, leading to GID
    # change failure.
    print "Switching to '$config->{Group}' group..." if DEBUG_MODE;
    POSIX::setgid( $gid );

    if (POSIX::getgid() == $gid) {
        print "Ok\n" if DEBUG_MODE;
        
    } else {
        print "Failed!\n" if DEBUG_MODE;
        die "Setting GID from $cgid to $gid failed: $!";
    }

    print "Switching to '$config->{User}' user..." if DEBUG_MODE;
    POSIX::setuid( $uid );

    if (POSIX::getuid() == $uid) {
        print "Ok\n" if DEBUG_MODE;
    } else {
        print "Failed\n" if DEBUG_MODE;
        die "Setting UID from $cuid to $uid failed: $!";
    }

}


sub set_sid {
    DEBUG "Setting the session identifier of the current process." if DEBUG_MODE;
    POSIX::setsid() unless ($^O eq "MSWin32");
}


#Close all file descriptors
sub close_files {
    foreach my $i (0 .. max_open_files()) {
        POSIX::close( $i );
    }
}


#Maximum number of possible file descriptors.
#If sysconf() does not give us value, we punt with our own value.
sub max_open_files {
    
    my $openmax = POSIX::sysconf(&POSIX::_SC_OPEN_MAX);
    
    if (!defined($openmax) || ($openmax < 0)) {
        $openmax = 128;
        DEBUG "_SC_OPEN_MAX variable returns nothing, assuming maximum open files value to be $openmax" if DEBUG_MODE;
    }

    return $openmax;
    
}


#return execution stack from the current call, without this sub call
# my $stack_string = join ("\n", Utils::execution_stack());
sub get_execution_stack {
    
    my $stack_level = 1; #start from zero gives this call as well
    my @stack = ();
    
    #run throught the end
    while () {
        
        my ($package, $filename, $line,
            $subroutine, $hasargs, $wantarray,
            $evaltext, $is_require, $hints,
            $bitmask, $hinthash) = caller($stack_level);
        
        if ($filename) {
            my $locationId = "$package:$subroutine() at $filename line $line";
            push (@stack, $locationId);
        } else {last;}
    
        $stack_level++;
    }    
    
    return @stack;
}


sub get_memory_used_by_agent {
    
    return () if ( $^O eq "MSWin32" );

    my $ps_cmd = "ps -p $$ -o ";

    $ps_cmd .= ( $^O eq 'solaris' ) ? 'vsz,rss' : 'vsize,rss';
    
    open my $ps, "$ps_cmd |" || return ();
    
    <$ps>; # skip first line
    my $data = <$ps>;
    
    chomp $data;
    $data =~ s/(^\s+|\s+$)//;
    
    my ($vsize, $rss) = split /\s+/, $data;
    
    return ($vsize, $rss);
    
}


#enables / disables terminal input echo
#Returns 0 on success, 1 on failure. 
sub enable_echo {
    
    my $is_on = shift;
    if ($^O eq 'MSWin32') {
        return enable_echo4Win32($is_on);
    } else {
        return enable_echo4Unix($is_on);
    }
    
}


sub enable_echo4Unix {
    
    die "This is not supposed to be called on MSWin32"
        if $^O eq 'MSWin32'; 
    
    my $is_on = shift;
    
    # getting terminal settings for stdin
    my $t = POSIX::Termios->new;
    my $settings = $t->getattr(0);

    return 1 if (!defined $settings);# getattr() failed

    # disabling input echo
    my $lfl = $t->getlflag;
    
    if($is_on) {
        $t->setlflag($lfl | &POSIX::ECHO);
    } else {
        $t->setlflag($lfl & ~(&POSIX::ECHO));
    }
    
    my $res = $t->setattr(0, &POSIX::TCSANOW);
    
    return 1 if (!defined $res);
    
    return 0;
    
}


sub enable_echo4Win32 {

    die "This is supposed to be called only on MSWin32"
        if $^O ne 'MSWin32';
        
    my $is_on = shift;
    
    require Term::ReadKey;
    Term::ReadKey::ReadMode ($is_on ? 0 : 2); # 2 - disable echo, 0 - set default mode
    return 0;
    
}


sub is_printable {
    my $str = shift;
    !($str =~ /[\x00-\x08\x0B-\x1F\x7F-\xFF]/);
}


sub dump_binary_data {
    
    my ($file, $data) = @_;
    
    open my $fh, ">>$file"
        or die "Can't open file '$file' to write a dump: $!";
        
    binmode $fh;
    my $length = syswrite $fh, $data;
    
    close $fh
        or die "Can't close file dump handler: $!";
    
    return $length;
}


sub touch_file {
    
    my $file = shift;

    return undef unless $file;   
    
    if ((-e $file) && (!-w $file)) {
        ERROR "Can't touch() '$file': permission denied";
        return undef;
    }
    
    open my $fh, ">>$file" or die "Can't open $file: $!";
    close $fh;

    return 1;
    
}

1;
