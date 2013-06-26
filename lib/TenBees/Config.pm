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

package TenBees::Config;
use warnings;
use strict;

our @EXPORT = qw/ DEBUG_MODE /;

use base 'Exporter';
use FindBin qw/ $Bin /;
use Config qw/ %Config /;
use Sys::Syslog qw/ :macros /;
use Config::General qw/ ParseConfig /;

use TenBees::Logger;

#Debugging options
use constant DEBUG_MODE => -e $Bin.'/debugMe' ? 1 : 0;

my $_cached_instance;

sub get {
    unless ($_cached_instance) {
        $_cached_instance = {};
        bless $_cached_instance;

        $_cached_instance->init();
    }

    return $_cached_instance;
}


sub lowercase_hash {
    my $hash = shift;

    for my $key (keys %$hash) {
        if (ref($hash->{$key}) eq 'HASH') {
            $hash->{lc($key)} = lowercase_hash(delete $hash->{$key});
        } else {
            $hash->{lc($key)} = delete $hash->{$key};
        }
    }

    return $hash;
}

sub parse_http_proxy {
    return ('', '') if !$ENV{http_proxy};

    my $str = $ENV{http_proxy};
    $str =~ s/^http:\/\///i;

    return split ':', $str;
}

sub init {
    my $self = shift;

    $self->{Version}='1.0'; # no spaces between variable and the value to support the perl's replace on Win32

    #Collector properties
    $self->{Hostname} = 'collector.10bees.com';
    $self->{Port} = 80;
    $self->{ServerTimeOut} = 5;
    $self->{ProtocolVersion} = '1.2';
    $self->{SleepTime} = 60;
    $self->{CollectorDumpName} = "$Bin/collector-reply.dump";
    
    #Run as
    $self->{User} = '10bees';              
    $self->{Group} = '10bees';

    #Files location, process title.
    $self->{ProcTitle} = '10bees-agent';
    $self->{ConfigFile} = "$Bin/agent.conf";
    $self->{Pid} = '/tmp/10bees.pid'; 
    $self->{HomeDir} = $Bin;    
    $self->{ProcSysInfoDumpName} = "$Bin/proc_sysinfo-error.dump";
    
    #Disk queue cache options
    $self->{DiskQueueFile} = "$Bin/.disk_queue";
    $self->{DiskQueueRecLen} = 300 * 1024;
    $self->{DiskQueueMaxSize} = 4 * 60;
    $self->{DiskQueueEOL} = "\xff\xff";
    $self->{DiskQueueLockTimeout} = 5;
    $self->{DiskQueueLockAttempts} = 2;

    #Dispatcher stuff
    $self->{DispatcherIsEnabled} = 0;

    #Sysinfo parameters
    $self->{IPCTimeout} = 5; # seconds
    $self->{ReadChunkSize} = 4096; # max sysread piece (bytes)

 
    #Filling other variables from the configuration file
    my %config_file_values;
    #if file doesn't exist it will be created later after init
    if((-e $self->{ConfigFile}) && (-s $self->{ConfigFile})) {
        eval {
            %config_file_values = ParseConfig($self->{ConfigFile});
        };
        die $@ if ($@);
    }
        
    %config_file_values = %{lowercase_hash(\%config_file_values)};
    
    #Filling main agent's fields
    $self->{HostId} = $config_file_values{host_id};
    $self->{AuthKey} = $config_file_values{auth_key} || undef;

    $self->{ProcSysInfoDir} = $config_file_values{procsysinfodir} || "lib"; # must by relative subdir, not absolute path for use in packager

    $self->{LogFile} = $config_file_values{logfile} || '';

    # handle relative logfile paths
    if($self->{LogFile} && (($^O eq 'MSWin32' && $self->{LogFile} !~ /^[A-Z]:/i)
        || ($^O ne 'MSWin32' && $self->{LogFile} !~ /^\//))) {

        $self->{LogFile} = "$Bin/$self->{LogFile}";
    }
    
    #Filling dispatcher's services
    $self->{services} = $config_file_values{services};

    #Registration params
    $self->{RegisterAttempts} = 3;

    #Proxy parameters
    if($config_file_values{proxy_host}) {
        $self->{ProxyHost} = $config_file_values{proxy_host};
        $self->{ProxyPort} = $config_file_values{proxy_port} || '';
    
    } else { # proxy not defined in config file, try to take from ENV
        ($self->{ProxyHost}, $self->{ProxyPort}) = parse_http_proxy();
    }

    return 1;
}

1;
