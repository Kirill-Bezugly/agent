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

package TenBees::Logger::File;
use warnings;
use strict;

use base 'Exporter';
our @EXPORT_OK = qw/ initialize /;


sub initialize {
    my $config = get TenBees::Config;

    open LOGHANDLER, '>>', $config->{LogFile}
        or die "Can't open log file '".$config->{LogFile}."' for writing";
    
    #Disable buffering
    my $prev_handler = select(LOGHANDLER);
    $| = 1;
    select($prev_handler);    

}


sub log_message {
    my $level = shift;
    my $message = shift;
    
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
        localtime(time);

    $year += 1900; $mon++;
    $mday = sprintf("%02d", $mday);
    $mon = sprintf("%02d", $mon);
    $hour = sprintf("%02d", $hour);
    $min = sprintf("%02d", $min);
    $sec = sprintf("%02d", $sec);
    
    $message = "|$$|$level|$mday/$mon/$year|$hour:$min:$sec".': '.$message;
    
    if (defined fileno(LOGHANDLER)) {
        syswrite(LOGHANDLER, "$message\n");
    } else {
        syswrite(STDERR, "$message\n");
    }
}


sub log_debug    { log_message 'DEBUG', @_ }
sub log_info     { log_message 'INFO',  @_ }
sub log_warn     { log_message 'WARNING',  @_ }
sub log_error    { log_message 'ERROR', @_ }
sub log_critical { log_message 'CRITICAL', @_}      


END {
    close LOGHANDLER;
}

1;
