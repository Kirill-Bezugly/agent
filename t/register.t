use warnings;
use strict;

use FindBin qw/ $Bin /;
use lib "$Bin/../lib";
use lib "$Bin/";

use TenBees::Config;
use TenBees::Delivery qw/ send2collector /;
use TenBees::Register;
use TenBees::ProcSysInfo qw/ get_sysinfo /;

use Digest::SHA qw/ sha1_hex /;
use Test::More qw/ no_plan /;

system('cp agent.conf agent.conf.backup');

my $config = TenBees::Config->get();
TenBees::Logger::initialize($config);

my $CORRECT_LOGIN='replaceme-login';
my $CORRECT_PASS=sha1_hex('replaceme-password');

my $INCORRECT_LOGIN='aaa@bbb';
my $INCORRECT_PASS='123qwe';

my $data = '';
get_sysinfo(\$data);


#
# Trying to perform proper registration
#

$config->{AuthKey} = $CORRECT_PASS;
$config->{HostId} = '';

my $result = send2collector('reg', \$data, {UserId => $CORRECT_LOGIN,});

my $error = undef;
my ($code, $host_id, $authkey) = TenBees::Register::parse_result($result, \$error);
ok($code == 200, "registration request with proper authentication data");


#
# Verifying if non-valid registration data will be rejected
#

$config->{AuthKey} = $INCORRECT_PASS;
$config->{HostId} = '';

$result = send2collector('reg', \$data, {UserId => $INCORRECT_LOGIN,});
($code, $host_id, $authkey) = TenBees::Register::parse_result($result, \$error);
ok($code == 401, "registration request with some random authentication data");


#
# Verifying non-interactive valid registration
#

my $CORRECT_CRED_FILE = "correct_creds";

open my $fhc, ">$CORRECT_CRED_FILE" or die "Can't open test cred file: $!";
print {$fhc} "$CORRECT_LOGIN\n$CORRECT_PASS\n";
close $fhc;

my $res = TenBees::Register::non_interactive_register($CORRECT_CRED_FILE);
ok($res == 1, "non-interactive registration request with proper authentication data");


#
# Verifying non-interactive registration with invalid data
#

my $INCORRECT_CRED_FILE = "incorrect_creds";

open my $fhi, ">$INCORRECT_CRED_FILE" or die "Can't open test cred file: $!";
print {$fhi} "$INCORRECT_LOGIN\n$INCORRECT_PASS\n";
close $fhi;

$res = TenBees::Register::non_interactive_register($INCORRECT_CRED_FILE);
ok($res == 0, "non-interactive registration request with some random authentication data");


system('cp agent.conf.backup agent.conf');