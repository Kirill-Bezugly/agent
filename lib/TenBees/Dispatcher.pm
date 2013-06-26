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

package TenBees::Dispatcher;
use warnings;
use strict;

use base 'Exporter';
our @EXPORT_OK = qw/ get_dispatcher_data /;

use TenBees::Config;
use TenBees::Logger;

my $empty_msgpack;

sub get_dispatcher_data {
    
    my $config = TenBees::Config->get();
    
    $config->{DispatcherIsEnabled} = 0; #completely disabled for now
    
    unless ($config->{DispatcherIsEnabled}) {
        unless ($empty_msgpack) {
            $empty_msgpack = Data::MessagePack->pack({});
        }
        return $empty_msgpack;
    }

    my $dispatcher_data;
    DEBUG 'Reading dispatcher data...';

    return $dispatcher_data;
}

1;

