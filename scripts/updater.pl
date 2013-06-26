#!/usr/bin/env perl

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

# ToDo:
# - verify and switch to root on *nix.
# - verify versions
# - safe log file creation

use warnings;
use strict;

use FindBin qw/ $Bin /;
use lib "$Bin";
use lib "$Bin/../lib";

use POSIX qw/ uname /;
use IPC::TBCmd qw/ run can_run /;
use File::Basename qw / basename /;
use Getopt::Long;

my $script_self_name = basename $0;

#Reading the arguments
#=====================
my ($noninteractive, $alternate_hostname, $usage_help) = (0, undef, undef);

GetOptions ("noninteractive"  => \$noninteractive,
	    "host=s" => \$alternate_hostname, #just the hostname
	    "help|?" => \$usage_help);

if ($usage_help) {
    print "$script_self_name --noninteractive\n";
    exit 0;
}

my $host_name = 'http://10bees.com';
if ($alternate_hostname) {
    $host_name = "http://$alternate_hostname";
}


my $download_folder = 'download';

#Getting platform information
my $os = lc($^O);
my $os_flavour = '';
my ($sysname, $nodename, $release, $version, $machine) = uname();

sub return_file_content {

    my $scriptFileName = shift;
    my $scriptOutput = undef;

    if (-e $scriptFileName) {
        open FILEHANDLER, $scriptFileName or die $!;
        $scriptOutput = do { local( $/ ); <FILEHANDLER> };
        close FILEHANDLER;
        
    } else {
        die "Can't find file $scriptFileName.\n"
    }

    return $scriptOutput;
}


#Update files 
sub download_from_web {

    my $file_name = shift;

    unlink $file_name if -e $file_name;
    
    my $url = "$host_name/$download_folder/$os/$file_name";
    
    my $cmd_line;
    
    if ($os eq 'linux') {
        
        if (can_run('curl')) {
            $cmd_line = "curl -s -S -O $url";
        } elsif (can_run('wget')) {
            $cmd_line = "wget -q $url";
        } else {
            die "Can't find nor curl, not wget.";
        }
        
    } elsif ($os eq 'freebsd') {
        $cmd_line = "fetch -q $url";
        
    } elsif ($os eq 'netbsd') {
        $cmd_line = "ftp -V $url";
        
    } elsif ($os eq 'openbsd') {
        $cmd_line = "ftp -V $url";
        
    } elsif ($os eq 'mswin32') {
	require LWP::Simple;
	LWP::Simple::getstore("$url", "$file_name");
        
    } elsif ($os eq 'darwin') {
        $cmd_line = "curl -s -S -O $url";

    }
    
    execute_command($cmd_line) if ($os ne 'mswin32');
    
    if (!-e $file_name || -z $file_name) {
	die "Can't find downloaded file '$file_name', execution stopped.";
    }
    
}


sub get_latest_agent_name {
    my $extension = shift;
    my $latest_file_name = "latest_agent.$extension.txt";
    
    #Implement at least basic HTTP errors check
    
    download_from_web($latest_file_name);
    
    return return_file_content($latest_file_name);    
}


#Init task
#=========
my $log_file = "10bees-$script_self_name.log";

$| = 1;

if (-e $log_file) {
    unlink $log_file
	or die "Can't remove previous log file '$log_file'.";
}

open LOGHANDLER, ">$log_file"
    or die "Can't open log file '$log_file' for writing: $!";

my $old_logh = select(LOGHANDLER);
$| = 1;
select($old_logh);


#Defining die() handler, which is raising a ticket on the system / print to the console.
#=======================================================================================
$SIG{__DIE__} = sub {
 
    my $message = "Can't update the agent for $os at $nodename: ";
    my $body = shift;
    $message .= "\n$body"; 
    
    if ($noninteractive) {
	print LOGHANDLER $message;
    } else {
	print $message;
    }
    
};


#Defining logger: open log, print, close (to ensure nothing is lost)
#===================================================================
sub log_message {
    
    my $message = shift || '';
    
    if (!$noninteractive) {
	print STDOUT "$message\n";
    }
    
    print LOGHANDLER $message
	or die "Can't write to the log file: $!";
    
    return 1;
}

sub error_on_agent_fresh_installation {
        log_message("Existing installation was not found, agent must be installed first.");
	die "Agent can be only upgraded with this script, but I can't find an existing installation.";
}

#Execution wrapper: execute, return result and full output, make a log
#=====================================================================
sub execute_command {
    
    my $cmd = shift;  

    my($success, $error_message, $full_buf, $stdout_buf, $stderr_buf) =
        run(command => $cmd, verbose => 0);

    if ($success) {
        log_message "'$cmd' executed Ok: ".join ('', @$full_buf);
    } else {
        log_message "'$cmd' execution failed: ".join ('', @$full_buf);
	die "'$cmd' execution failed: $error_message, STDERR output: ".join "", @$stderr_buf;
    }
    
    return $success;
}

sub get_console_confirmation {

    if (!$noninteractive) {
	
	my $agent_installation_name = shift;
	
	use Term::ReadLine;
	my $term = Term::ReadLine->new($0);
	$term->ornaments(0);
	
	if(!defined $term) {
	    die "Can't access terminal";
	}
    
	print "Found the following latest package '$agent_installation_name'\nShall I update?";
	my $answer = $term->readline(" [Y]es/[N]o ");
	
	if ($answer =~ m/y.*/i) {
	    return 1;
	} else {
	    die "Didn't get a confirmation to continue with the update.";
	}
	
    }

}

my $agent_file_name;

if( $os eq 'linux' ) {

    if (can_run('dpkg')) {
        
	$agent_file_name = get_latest_agent_name("deb");
      
        #installed
        if (system('dpkg -l | grep -q 10bees') == 0) {
            log_message("10bees agent found, upgrading.");
        } else {
	    error_on_agent_fresh_installation();
        }
        
	get_console_confirmation($agent_file_name);
	
	download_from_web($agent_file_name);
	
        log_message("Agent $agent_file_name fetched, installing...");
        execute_command("dpkg -i $agent_file_name");
        
    } elsif (can_run('rpm')) {
        
	$agent_file_name = get_latest_agent_name("rpm");
        
        #installed
        if (system('rpm -qa | grep 10bees') == 0) {
	    
            log_message("10bees agent found, upgrading...");
	    
	    get_console_confirmation($agent_file_name);
	    
	    download_from_web($agent_file_name);
	    
	    log_message("Agent $agent_file_name fetched, installing...");
            execute_command("rpm -Uvh $agent_file_name");
            
        } else {
            error_on_agent_fresh_installation();
        }
        
    }
    
} elsif ($os eq 'freebsd') {
    
    $agent_file_name = get_latest_agent_name("tbz");
    
    get_console_confirmation($agent_file_name);
    
    download_from_web($agent_file_name);
    
    #installed
    my $grep_package_code = system('pkg_info | grep 10bees');
    if (($grep_package_code == 0) || ($grep_package_code == 256)) { #0 - from shell, 256 - from crontab...
        log_message("Deleting existent package...");
        execute_command('pkg_delete 10bees\*');  
    } else {
	error_on_agent_fresh_installation();
    }
    
    log_message("Agent $agent_file_name fetched, installing...");
    execute_command("pkg_add $agent_file_name");
    
} elsif ($os eq 'netbsd') {
    
    $agent_file_name = get_latest_agent_name("tgz");
    
    get_console_confirmation($agent_file_name);
    
    download_from_web($agent_file_name);
    
    #installed
    if (system('pkg_info | grep 10bees') == 0) {
        log_message("Updating existing package...");
        execute_command("pkg_add -m x86_64 -u $agent_file_name"); #use 'pkg_add -D arch', if re-installation, not upgrade
        #Re-enabling automatic startup, that was disabled during the package update
        execute_command("cp /usr/pkg/share/examples/rc.d/tenbees /etc/rc.d/tenbees");
        execute_command("chmod 07555 /etc/rc.d/tenbees");
        
    } else {
        error_on_agent_fresh_installation();
    } 

} elsif ($os eq 'openbsd') {
    
    $agent_file_name = get_latest_agent_name("tgz");
    
    get_console_confirmation($agent_file_name);
    
    download_from_web($agent_file_name);
    
    #installed
    if (system('pkg_info | grep 10bees') == 0) {
	log_message("Removing the package...");
	execute_command('pkg_delete 10bees');  
        log_message("(Re)installing the package...");
        execute_command('pkg_add -D arch 10bees');  
    } else {
        error_on_agent_fresh_installation();
    }

} elsif ($os eq 'mswin32') {
    
    $agent_file_name = get_latest_agent_name("exe");
    
    get_console_confirmation($agent_file_name);
    
    log_message("Downloading confirmed '$agent_file_name'...");
    
    download_from_web($agent_file_name);
    
    log_message("Installing the package '$agent_file_name'...");
    
    #Silent installation, silent deinstall executed automatically
    execute_command($agent_file_name.' /S');
    
} elsif ($os eq 'darwin') {
    
    $agent_file_name = get_latest_agent_name("pkg");
    
    get_console_confirmation($agent_file_name);
    
    download_from_web($agent_file_name);

    my $mac_os_ver = substr($release, 0, 2);
    
    my $command;
    
    if ($mac_os_ver >= 11) { #MacOS X 10.7 and above
	$command = "sudo installer -pkg $agent_file_name -allowUntrusted -target /";
    } elsif (($mac_os_ver < 11)) { #MacOS X 10.6 (trusted / untrusted stuff is not yet know)
	$command = "sudo installer -pkg $agent_file_name -target /";
    } else { #?
	die "Unknown Darwin release: $mac_os_ver";
    }
    
    log_message("Installing the package '$agent_file_name' for Darwin $mac_os_ver (cmd='$command')...");
    
    execute_command($command);
    
} else {
    die "OS $os is not (yet) supported.";
}

exit(0);