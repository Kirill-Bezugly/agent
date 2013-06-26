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

package TenBees::Logger;
use warnings;
use strict;
no strict 'refs';

use base 'Exporter';
our @EXPORT = qw/
    DEBUG
    INFO
    WARN
    ERROR
    CRITICAL
/;
use FindBin qw/ $Bin /;

use TenBees::Logger::Syslog;
use TenBees::Logger::Stderr;
use TenBees::Logger::File;

our $logger_backend = $^O eq 'MSWin32' ? 'TenBees::Logger::File' : 'TenBees::Logger::Syslog';
our $default_log_file = "$Bin/agent.log";


sub initialize {
    my $config = shift; # require it here to avoid circular dependency between TenBees::Config and Tenbees::Looger

    if ($ENV{'LOG_STDERR'}) {
        $logger_backend = 'TenBees::Logger::Stderr';
    } elsif ($config->{LogFile}) {
        $logger_backend = 'TenBees::Logger::File';
    }

    if($logger_backend eq 'TenBees::Logger::File' && !$config->{LogFile}) {
        $config->{LogFile} = $default_log_file;
    }
    
    &{$logger_backend.'::initialize'}($config, @_);
}


sub set_backend {
    
    my $config = shift;
    my $backend = shift;
    my $new_backend = "TenBees::Logger::$backend";
    
    if ($new_backend ne $logger_backend) {
        $logger_backend = $new_backend;
        &{$logger_backend.'::initialize'}($config, @_);
    }
}


sub DEBUG    { &{$logger_backend.'::log_debug'}, @_ }
sub INFO     { &{$logger_backend.'::log_info'},  @_ }
sub WARN     { &{$logger_backend.'::log_warn'},  @_ }
sub ERROR    { &{$logger_backend.'::log_error'}, @_ }
sub CRITICAL { &{$logger_backend.'::log_critical'}, @_}


$SIG{__WARN__} = sub {
    #Ignore: "Cannot find termcap: TERM not set" under the Windows, no fix available for now
    return if $_[0] =~ m{^Cannot find termcap.* TERM not set};
    
    #Termcap database file was substituted by terminfo and no longer shipped with NetBSD starting from 6.0
    return if (($^O eq 'netbsd') && ($_[0] =~ m{^Cannot find termcap.*Can't find a valid termcap file}));

    #Ignore: Name "TenBees::ProcSysInfo::*SAVE" used only once: possible typo at .../ProcSysInfo.pm
    return if $_[0] =~ m{^Name.*ProcSysInfo.*SAVE" used only once: possible typo at.*};
    
    #Ignore: Perl 5.8 only warning - cause no impact on the agent, just spam the logs
    return if $_[0] =~ m{^unix passed to setlogsock, but path not available at.*};
    
    ERROR '(perl warn) '.$_[0];    
};


$SIG{__DIE__} = sub {
    
    unless (defined $^S) {
    #Ignore Term::ReadLine eval() die()'s during plugins load
        return if $_[0] =~ m{^Can't locate Term/ReadLine/.*\.pm};
    }

    return if $^S; # Ignore errors inside eval block

    # Ignore message about invalid type 'Q' in pack for 32bit machines
    return if $_[0] =~ /Invalid type 'Q' in pack/;

    CRITICAL $_[0];
}; 

1;
