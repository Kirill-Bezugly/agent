use warnings;
use strict;

use FindBin qw/ $Bin $Script /;
use lib "$Bin/../lib";
use lib "$Bin/";

use TenBees::Config;
use TenBees::Logger;

use Test::More qw/ no_plan /;

use constant LOGFILE => "log_file_for_test";

#
# Verify that the config file doesn't exist before the tests
#
my $config = TenBees::Config->get();
$config->{LogFile} = LOGFILE;

unlink LOGFILE;
ok(!-f LOGFILE, "log file is not expected to be there");

#
# Verify if config file could be created succesfully
#
TenBees::Logger::initialize($config);
ok(-f LOGFILE, "log file created succesfully during the initialize() call");

#
# Trying to make a log entry
#
my $TESTMSG = "TESTTESTTEST$$";
eval {
    INFO $TESTMSG;
};
ok(!$@, "log entry posted");

#
# Verifying if the log entry could be read succesfully
#
open my $fh, "<", LOGFILE or die "Can't open log file for reading";
my $text = do {
    local $/ = undef;
    <$fh>;
};
close $fh;
ok(scalar(grep { /$TESTMSG/; } $text) > 0, "log entry post verified");
