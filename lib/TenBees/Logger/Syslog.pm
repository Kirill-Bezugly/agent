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

package TenBees::Logger::Syslog;
use warnings;
use strict;

use base 'Exporter';
our @EXPORT_OK = qw/ logger_backend initialize_backend /;

use Sys::Syslog qw/ :standard :macros closelog setlogsock /;

my $os = lc($^O);

BEGIN {
    no strict 'refs';
    *{logger_backend} = *syslog; # create an alias for 'syslog' function
}


sub initialize {
    my $config = shift;
    
    #Open syslog
    openlog(
        $config->{ProcTitle},
        'ndelay,nowait,pid',
        LOG_USER
    );

    # Perl v5.8.x
    if ($^V lt v5.10.0) {
        setlogsock("unix", "/dev/log");
        setlogmask((1 << (LOG_DEBUG + 1)) - 1);
    } else {
        setlogmask(LOG_UPTO(LOG_DEBUG));    
    }
}

#Got to differentiate reporting level, due to the different syslog configuration by default
#LOG_NOTICE is printed directly to the console on Linux, but LOG_INFO is silently ignored by MacOS X
my $reporting_level = ($os eq 'darwin') ? LOG_NOTICE : LOG_INFO;

#All syslog entries to be send via INFO to ensure daemon's entries won't get lost
#In many *nixes debugging log messages are not saved.
sub log_debug    { syslog $reporting_level, @_ }
sub log_info     { syslog $reporting_level, @_ }
sub log_warn     { syslog $reporting_level, @_ }
sub log_error    { syslog $reporting_level, @_ }
sub log_critical { syslog $reporting_level, @_ }


END {
    closelog();
}

1;
