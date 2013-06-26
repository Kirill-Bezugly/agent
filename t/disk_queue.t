use warnings;
use strict;

use FindBin qw/ $Bin /;
use lib "$Bin/../lib";
use lib "$Bin/";


use Data::MessagePack;
use TenBees::DiskQueue;
use TenBees::ProcSysInfo qw/ get_sysinfo /;
use TenBees::Dispatcher qw/ get_dispatcher_data /;

use Data::MessagePack;

use POSIX;
use Digest::SHA qw/ sha1_hex /;
use Test::More qw/ no_plan /;

use constant NBYTES => 256;
use constant ITERATIONS => 10;

my $config = TenBees::Config->get();
TenBees::Logger::initialize($config);

my @chunks;
my @curr_queue = ();

my $len = 0;

for(my $i = 0; $i < ITERATIONS; ++$i) {
	
	eval {
		TenBees::DiskQueue->initialize();
	};
	ok(!$@, "initialize()");
	
	my $qlen = undef;
	eval {
		$qlen = TenBees::DiskQueue->get_length();
	};
	ok(!$@, "get_length()");
	ok($qlen == $len, "get_length() result, immediately after the init");
	
	my $agent_data_msgpack = Data::MessagePack->pack({
		agent_version => $config->{Version},
	});
	
	my $sysinfo = '';
	get_sysinfo(\$sysinfo);
	
	my $packed_new_record = $agent_data_msgpack.$sysinfo.get_dispatcher_data();
	
	push @chunks, $packed_new_record;
	$len++;
	eval {
		TenBees::DiskQueue->save_record($packed_new_record);
	};
	ok(!$@, "save_record()");
	
	eval {
		$qlen = TenBees::DiskQueue->get_length();
	};
	ok(!$@, "get_length() after save_record()");
	ok($qlen == $len, "get_length() result, after save_record()");
	
	@curr_queue = ();
	my $curr_n = undef;
	eval {
		$curr_n = TenBees::DiskQueue->read_all(\@curr_queue);
	};
	ok(!$@, "read_all()");
	ok($curr_n == $len && $curr_n == scalar(@curr_queue), "read_all() returned queue length");
	
	eval {
		TenBees::DiskQueue->uninitialize();
	};
	ok(!$@, "uninitialize()");
}

for(my $i = 0; $i < $len; ++$i) {
	my $orig_sum = sha1_hex($chunks[$i]);
	my $queue_sum = sha1_hex($curr_queue[$i]);
	ok( $orig_sum eq $queue_sum, "records $i are equal");
}

eval {
	TenBees::DiskQueue->initialize();
};
ok(!$@, "initialize() after uninitialize()");


# testing locks
# Commented out, as require rework with SIG{CHLD} handler
#my $pid = fork();
#
#if($pid == 0) { # child
#
#    eval {
#        TenBees::DiskQueue->initialize();
#    };
#    exit 0 if $@;
#
#    TenBees::DiskQueue->uninitialize();
#    exit 1;
#
#} elsif(defined $pid) { # parent
#    waitpid($pid,0);
#    my $res = $^O eq 'MSWin32' ? $? : WEXITSTATUS($?);
#    ok($res == 0, "Failed to initialize disk queue from second process");
#
#} else {
#    diag("Failed to fork: $!");
#}

eval {
	TenBees::DiskQueue->remove_elems($len);
};
ok(!$@, "remove_elems()");

my $qlen = undef;
eval {
	$qlen = TenBees::DiskQueue->get_length();
};
ok(!$@, "get_length() after remove_elems()");
ok($qlen == 0, "get_length() size is zero after remove_elems()");

eval {
	TenBees::DiskQueue->uninitialize();
};
ok(!$@, "uninitialize() after removing disk queue records");

eval {
	TenBees::DiskQueue->cleanup();
};
ok(!$@, "cleanup()");
ok(! -e $config->{DiskQueueFile}, "cleanup() removed disk queue file");

