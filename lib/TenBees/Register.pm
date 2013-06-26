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

package TenBees::Register;
use warnings;
use strict;

our @EXPORT    = qw//;
our @EXPORT_OK = qw/ host_registered register /;

use base 'Exporter';
use FindBin qw/ $Bin $Script /;
use Digest::SHA qw/ sha1_hex /;
use Term::ReadLine;

use TenBees::Logger;
use TenBees::Config;
use TenBees::Delivery qw/ send2collector /;
use TenBees::ProcSysInfo qw/ get_sysinfo /;
use TenBees::Utils qw/ enable_echo dump_binary_data /;

use constant OK => 200;
use constant BAD_REQUEST => 400;
use constant UNAUTHORIZED => 401;
use constant FORBIDDEN => 403;
use constant NOT_FOUND => 404;
use constant INTERNAL_ERROR => 500;

our $term;


sub prepare_terminal {
    DEBUG "Preparing terminal handle" if DEBUG_MODE;
    $term = Term::ReadLine->new($0);
    $term->ornaments(0);
}


sub host_registered {
    
    my $config = TenBees::Config->get();

    if(!(defined $config->{HostId} && defined $config->{AuthKey})) {
        DEBUG "Can't find proper host id, auth. key (host is not registered)." if DEBUG_MODE;
        return 0;
    }
    
    return 1;
}


sub validate_user_id {
    my $user_id = shift || '';

    return if length ($user_id) < 4;
    return $user_id =~ /^[\w\d.@\-]+$/;
}


sub validate_password {
    my $password = shift || '';

    return if length($password) < 3;
    return 1;
}


sub get_login {
    
    if(!defined $term) {
        ERROR "Can't access terminal";
        return undef;
    }

    my $user_id = $term->readline('Login (e-mail): ');

    if (!validate_user_id($user_id)) {
        INFO "Login is incorrect, please try again.";
        return undef;
    }

    return $user_id;
}


sub get_password {

    DEBUG "Disabling terminal echo for the password input." if DEBUG_MODE;

    my $res = enable_echo(0);
    
    if($res) {
        WARN "Failed to disable password echo: $!";
        WARN "Your password will be displayed!";
    }

    my $password = $term->readline('Password: ');

    if (!$res) { # if we didn't fail to disable terminal echo enable it back
        $res = enable_echo(1);
        print "\n"; # add new line to make output nice
        if($res) {
            WARN "Failed to restore characters echo setting: $! - your input might be hidden.";
        }
    }

    if (!validate_password($password)) {
        INFO "Password doesn't seem to be valid - please try again.";
        return undef;
    }
    
    return $password;
}


sub send_data {

    my ($user_id, $data) = @_;

    DEBUG 'Sending user and sysinfo data to the server.' if DEBUG_MODE;
    my $result = send2collector('reg', $data, {UserId => $user_id,});

    @{$result} = split(/(?:\015)?\012/, $result->[0]);

    return $result;
}


sub dump_server_reply {
    
    my $reply = shift;
    my $config = TenBees::Config->get();
    ERROR "Server replied back with something odd. Please, try again in a few seconds.";
    my $filename = $config->{CollectorDumpName}.'.'.time();

    my $len = dump_binary_data($filename, join "\015\012", @$reply);
        
    if(defined $len) {
        DEBUG "$len bytes of collector reply were dumped to $filename" if DEBUG_MODE;
        ERROR "If it continues to fail - please contact 10bees.com/support, providing server's reply ($filename)";
        
    } else {
        DEBUG "Tried to dump collector reply to $filename, but failed: $!" if DEBUG_MODE;
        ERROR "If it continues to fail - please contact 10bees.com/support, providing full error output.";
    }

    return $len ? $filename : '';
}


# takes server reply result and reference to error message
# returns list of code/host_id/authkey if result is ok
# otherwise returns undefs as id/key and sets error message
sub parse_result {

    my ($result, $error) = @_;

    my $code = undef;
    my $host_id = undef;
    my $authkey = undef;

    $$error = 'Registration has failed: ';

    if ($result->[0] =~ /200 OK/i) {
        $code = OK;
        $host_id = $result->[-2];
        $authkey = $result->[-1];
        $$error = '';

    } elsif ($result->[0] =~ /400 BAD REQUEST/i) {

        $code = BAD_REQUEST;
        $$error .= 'bad request or protocol error.';
        
    } elsif ($result->[0] =~ /401 UNAUTHORIZED/i) {

        $code = UNAUTHORIZED;
        $$error .= 'authorization error.';

    } elsif ($result->[0] =~ /403 FORBIDDEN/i) {

        $code = FORBIDDEN;
        $$error .= 'authorization error.';
        
    } elsif ($result->[0] =~ /404 NOT FOUND/i) {

        $code = NOT_FOUND;
        $$error .= 'incorrect URI.';

    } elsif ($result->[0] =~ /500 INTERNAL SERVER ERROR/i) {
        
        $code = INTERNAL_ERROR;
        $$error .= 'internal server error';
    
    } elsif($result->[0] =~ /^HTTP\/1\.[01] (.+)$/) {

        $$error .= 'server replied unhandled error: '.$1;

    } elsif ($result->[0] =~ /^Local error: (.+?) at.*$/) {

        $$error .= 'unknown (local) error: '.$1;

    } else {

        $$error .= 'unknown and unpredicted error occured, please, seek support help.';

    }

    if (!$code) {
        
        CRITICAL "Can't recognize server reply:";
        CRITICAL $result->[0];
        die "Collector provided a reply ($result->[0]), I can't recognize. Data were not delivered to the server.";
    }
    
    return ($code, $host_id, $authkey);
}


sub update_config {
    
    my ($host_id, $authkey) = @_;
    my $config = TenBees::Config->get();
    my @lines;
        
    if (-e $config->{ConfigFile}) {
              
        DEBUG 'Configuration file found, looking for the previous host id and auth. key entries.' if DEBUG_MODE;
                
        open(my $f, $config->{ConfigFile}) or die "Can't open configuration file ".$config->{ConfigFile}.": $!";
        @lines = <$f>;
        close $f;
        
        @lines = grep { $_ !~ /^\s*(HostId|AuthKey)/i } @lines;
    }

    DEBUG 'Appending newly obtained host id and auth. key values.' if DEBUG_MODE;
            
    #append new items
    unshift @lines, "host_id = $host_id\012";
    unshift @lines, "auth_key = $authkey\012";

    DEBUG 'About to write updated configuration file.' if DEBUG_MODE;

    #write file
    open(my $f, '>'.$config->{ConfigFile}) or die "Failed to open configuration file ".$config->{ConfigFile}.": $!";

    print $f $_ for @lines;

    close $f or die "Can't close file ".$config->{ConfigFile}." after writing: $!";

    DEBUG "Configuration file updated ($host_id / $authkey) successfully, ready to go now." if DEBUG_MODE;
}


sub process_success {
    
    my ($host_id, $authkey) = @_;
    
    DEBUG "Host registered on the collector. Host id: $host_id, auth. key: $authkey." if DEBUG_MODE;
    DEBUG 'About to update configuration file with host id and auth. key provided by the server.' if DEBUG_MODE;
    update_config($host_id, $authkey);
    
    INFO "Registration successful (id=$host_id). Please start the agent with: ";

    my $os = lc($^O);
    
    if ($os eq 'linux') {
        INFO "sudo service 10bees-agent start";
        
    } elsif ($os eq 'freebsd') {
        INFO "sudo service tenbees start";

    } elsif ($os eq 'netbsd') {
        INFO "sudo /etc/rc.d/tenbees start";
        
    } elsif ($os eq 'openbsd') {
        INFO "sudo /etc/rc.d/tenbees start";
        
    } elsif ($os eq 'mswin32') {
        INFO "net start 10bees-agent";
        
    } elsif ($os eq 'darwin') {
        INFO "sudo launchctl start com.10bees.agent";
        
    } elsif ($os eq 'solaris') {
        INFO "svcadm enable tenbees-agent";
        
    } else {
        INFO "$Bin/$Script start";
    }
    
    INFO "";
    
return 1;
}


sub interactive_register {

    my $config = TenBees::Config->get();
    
    DEBUG "Agent is running in interactive mode, logger's output set to STDERR" if DEBUG_MODE;
    TenBees::Logger::set_backend($config, 'Stderr');
    prepare_terminal();

    INFO '';
    INFO 'This will register this machine at the central server.';
    INFO 'Please, provide your username and password created at 10bees.com and you are done.';
    INFO 'If you don\'t have one, then point your browser to http://10bees.com/signup';
    INFO '';
 
    my $attempts = $config->{RegisterAttempts};
    while ($attempts--) {
        
        my $user_id = get_login();
        if (!defined $user_id) {
            WARN "Failed to get valid login (attempts left: $attempts).";
            next;
        }

        my $password = get_password();
        if (!defined $password) {
            WARN "Failed to get valid password (attempts left: $attempts).";
            next;
        }
        
        $config->{AuthKey} = sha1_hex($password);
        $config->{HostId} = '';

        DEBUG 'Getting sysinfo module data.' if DEBUG_MODE;
        my $data = '';
        get_sysinfo(\$data);

        my $result = send_data($user_id, \$data);
        
        my $error = '';
        my ($code, $host_id, $authkey) = parse_result($result, \$error);

        if (defined $code && ($code == OK)) {
            process_success($host_id, $authkey);
            return 1;
            
        } elsif (defined $code && ($code == UNAUTHORIZED)) {
            WARN "Authentication failed - please try again (attempts left: $attempts).";
            WARN '';
            $user_id = $password = undef;
            next;
            
        } else {
            
            ERROR $error;
            my $dump = dump_server_reply($result);
            
            if($dump) {
                ERROR "Failed to register, server reply dump: $dump";
                
            } else {
                ERROR "Failed to register and failed to dump server reply to file.";
            }
            
            return 0;
        }
    }

    return 0;
}


sub get_credentials_from_file {
    
    my $file = shift;
    my $login = undef;
    my $hash = undef;
    
    open my $fh, "<$file" or die "Can't open $file for reading: $!";
    
    $login = <$fh>;
    chomp $login;
    
    $hash = <$fh>;
    chomp $hash;
    
    close $fh;
    
    return ($login, $hash);
}


sub non_interactive_register {
    
    my $credentials_file = shift;

    my $config = TenBees::Config->get();

    DEBUG "Getting login and password hash from $credentials_file" if DEBUG_MODE;
    my ($user_id, $hash) = get_credentials_from_file($credentials_file);
    
    DEBUG "Read user_id = '$user_id', hash = '$hash' from the '$credentials_file' " if DEBUG_MODE;
    
    if (!validate_user_id($user_id)) {
        ERROR "Provided e-mail is not correct.";
        return 0;
    }

    DEBUG 'Getting sysinfo module data.' if DEBUG_MODE;
    my $data = '';
    get_sysinfo(\$data);

    $config->{AuthKey} = $hash;
    $config->{HostId} = '';

    my $result = send_data($user_id, \$data);
        
    my $error = '';
    my ($code, $host_id, $authkey) = parse_result($result, \$error);

    if($code == OK) {
        process_success($host_id, $authkey);
        return 1;
        
    } else {
        ERROR "Non-interactive registration failed: $error";
        dump_server_reply($result);
        return 0;
    }

    return -1;
}


sub register {
    
    if (host_registered()) {
        WARN "Registration requested for the previously registered agent, skipping.";
        return 255;
    }
    
    my $credentials_file = shift;
    my $interactive_mode = !$credentials_file;
    
    if($interactive_mode) {
        return interactive_register();
    } else {
        return non_interactive_register($credentials_file);
    }
}

1;
