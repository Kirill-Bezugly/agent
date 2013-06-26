use warnings;
use strict;

use FindBin qw/ $Bin /;
use lib "$Bin/../lib";
use lib "$Bin/";


use TenBees::Config;
use TenBees::Logger;
use TenBees::Register qw/ host_registered/;
use TenBees::ProcSysInfo qw/ get_sysinfo /;
use TenBees::Dispatcher qw/ get_dispatcher_data /;
use TenBees::Agent;

use Data::MessagePack;

use POSIX;
use Test::More qw/ no_plan /;

my $config = TenBees::Config->get();
TenBees::Logger::initialize($config);

#
# Basic sysinfo call works
#
my $sysinfo = '';
eval {
    get_sysinfo(\$sysinfo);
};
ok(!$@, "get_sysinfo()");

#
# Verify if information could be delivered and accepted by the collector
#
my $agent_data_msgpack = Data::MessagePack->pack({
    agent_version => $config->{Version},
});

my $dispatcher_data_msgpack = Data::MessagePack->pack(undef);

my $msgpack = $agent_data_msgpack.$sysinfo.$dispatcher_data_msgpack;

my $sendResult;
SKIP: {
    skip "Feature doesn't work correctly for win32", 1 if $^O eq 'MSWin32'; #TODO: Why?
    $sendResult = TenBees::Agent::send_records([$msgpack], 1);
    ok(($sendResult == 200), "send_records(valid data)");
}

#
# Verify if collector will reject corrupted MsgPack data
#
$msgpack = substr $msgpack, 0, length($msgpack)/2;
$sendResult = TenBees::Agent::send_records([$msgpack], 1);
ok(($sendResult == 400), "send_records(bad data) - got server reply = $sendResult");

#
# Verify if collector will reject non binary data at all
#
my $string = "Hello, I am just a test string, nothing special";
$sendResult = TenBees::Agent::send_records([$string], 1);
ok(($sendResult == 400), "send_records(plain string) - got server reply = $sendResult");

