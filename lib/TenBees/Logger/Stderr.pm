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

package TenBees::Logger::Stderr;
use warnings;
use strict;

use base 'Exporter';
our @EXPORT_OK = qw/ logger_backend initialize_backend /;

our $print_prefix = 1;


sub initialize {
    my $config = shift;
    my %opts = @_;

    return 1;
}


sub log_message {
    my $level = shift;
    my $message = shift;

    print STDERR $message,"\n";
}


sub log_debug    { log_message 'DEBUG', @_ }
sub log_info     { log_message 'INFO',  @_ }
sub log_warn     { log_message 'WARNING',  @_ }
sub log_error    { log_message 'ERROR', @_ }
sub log_critical { log_message 'CRITICAL', @_}      

1;