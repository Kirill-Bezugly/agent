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

package TenBees::ProcSysInfo;
use warnings;
use strict;

use TenBees::Config;
use TenBees::Logger;
use TenBees::Agent;

use base 'Exporter';
our @EXPORT_OK = qw/ get_sysinfo ping_sysinfo /;

use IPC::TBOpen3 qw/ open3 /;
use IO::Select;
use Cwd qw / cwd /;
use POSIX qw/ :sys_wait_h uname /;
use Config qw/ %Config /;

use TenBees::Utils qw/ is_printable dump_binary_data /;

my ($pid, $stdin, $stdout, $stderr);
my ($process_instances_counter, $process_instances_limit) = (0, 15); #how many times proc_sysinfo can be started
my $config = TenBees::Config->get();

$SIG{PIPE} = 'IGNORE';

$SIG{CHLD} = sub {
  while ((my $child = waitpid(-1, WNOHANG)) > 0)  {
    DEBUG "Processing SIG{CHLD}, reaping $child" if DEBUG_MODE;
  }
};


sub binary_name {
    
    if($^O eq 'MSWin32') {
        
        return "proc_sysinfo-mswin32-x86.exe";
        
    } elsif ($^O eq 'darwin') {
        
        chomp(my $darwin_arch = `uname -m`); #the only reliable way to get OS's "bitness"

        if ($darwin_arch eq 'x86_64') {
            DEBUG "64bit Darwin found." if DEBUG_MODE;
            
        } elsif ($darwin_arch eq 'i386') {
            DEBUG "32bit Darwin found." if DEBUG_MODE;
            
        } else {
            ERROR "Sorry, can't recognize '$darwin_arch' architecture (only aware of 'x64_64' and 'i386').";
        }
        
        return "proc_sysinfo-$^O-$darwin_arch";
        
    } else { #Linux, Solaris and *BSD based distributions
        
	my ($sysname, $nodename, $release, $version, $machine) = POSIX::uname();
        return lc("proc_sysinfo-$^O-$machine");
    }
}


sub ping_sysinfo {
    
    DEBUG "Pinging proc_sysinfo" if DEBUG_MODE;
    
    if ($^V lt v5.10.0) {
        DEBUG "Detected an old Perl ($^V) - restarting the proc_sysinfo instead, to avoid the IPC issues." if DEBUG_MODE;
        get_check_process('term');
        return 1; 
    }
    
    get_check_process();

    eval {
        my $answer = '';
        send_command("ping", \$answer);
        DEBUG "Got answer '$answer' from the proc_sysinfo." if DEBUG_MODE;
    };
    
    if ($@) {
        WARN "proc_sysinfo didn't reply on ping in time ($@), restarting.";
        get_check_process('force');
    }    
    
    DEBUG "touching $config->{Pid}" if DEBUG_MODE;
    utime (undef, undef, $config->{Pid});
    
    return 1;
}


sub get_sysinfo_win32 {

    my $output = shift;
     
    my $stdout = $ENV{TEMP}.'\10bees-proc_sysinfo_out';
    my $stderr = $ENV{TEMP}.'\10bees-proc_sysinfo_err';
    
    my $binaryName = join '\\', ($config->{HomeDir}, $config->{ProcSysInfoDir} , binary_name());
    $binaryName = '"'.$binaryName.'"';
    
    DEBUG "Truncating previous output files ('$stdout', '$stderr')" if DEBUG_MODE;
    my $stdoutfh; open $stdoutfh, '>', $stdout; close $stdoutfh;
    my $stderrfh; open $stderrfh, '>', $stderr; close $stderrfh;
    
    my $cmdline = $binaryName;
    $cmdline .= ' -cmd="get sysinfo"';
    $cmdline .= ' -stdout_file="'.$stdout.'"';
    $cmdline .= ' -stderr_file="'.$stderr.'"';
    
    $cmdline =~ s|\/|\\|g;
    $cmdline =~ s|\\|\\\\|g;

    DEBUG 'About to execute: "'.$cmdline.'"' if DEBUG_MODE;
    
    my $code = system ($cmdline);

    DEBUG "Checking proc_sysinfo stdout output (returned code: $code)" if DEBUG_MODE;
    
    if(!-z $stderr) {
        DEBUG "Reading sysinfo stderr output from $stderr" if DEBUG_MODE;
        open my $err, "<$stderr" or die "Can't open STDERR file $stderr for reading: $!";
        $$output = do { local $/; <$err>; }; 
        close $err;
        report_process_error(\$output);
    }
    
    if(!-z $stdout) {

        DEBUG "Reading sysinfo stdout output from $stdout" if DEBUG_MODE;
        open my $out, "<$stdout" or die "Can't open $stdout for reading: $!";
        $$output = do { local $/; <$out>; };
        close $out;
        
        DEBUG "Data read from STDOUT - assumed to be a proper binary output, returning it." if DEBUG_MODE;
        return;
        
    }
        
    WARN "Can't get STDOUT, STDERR.";
    return;        
}


sub get_sysinfo {

    my $output = shift;
    $$output = '';
    
    return get_sysinfo_win32($output) if $^O eq 'MSWin32';
    
    get_check_process();
    
    DEBUG "get_check_process() finished, pid: $pid" if DEBUG_MODE;
    die "Failed to start sysinfo" unless $pid;

    my ($attempts, $curr_attempt) = (2, 0);

    DEBUG "Getting sysinfo data..." if DEBUG_MODE;
    
    while ($attempts) {
        
        $attempts--; $curr_attempt++;
        
        DEBUG "Trying to get sysinfo data [curr: $curr_attempt / left: $attempts]" if DEBUG_MODE;
        
        eval {
            send_command("get sysinfo", $output);
        };
        
        if ($@) {
            DEBUG "Communication with proc_sysinfo failed, about to complain and try again (curr: $curr_attempt / left: $attempts)." if DEBUG_MODE;
            WARN "Failed to communicate with sysinfo module: $@";
        }

        if ($$output) {
            DEBUG "Got sysinfo data [curr: $curr_attempt / left: $attempts], working with it." if DEBUG_MODE;
            
            #If we are on debug mode, let us verify data structure before sending it to the collector server
            if (DEBUG_MODE) {
                
                require Data::MessagePack;
                
                use bytes;
                my $output_length = bytes::length($$output);        
                no bytes;
                
                DEBUG "About to verify (unpack) $output_length bytes long data localy.";
                
                local $Data::Dumper::Terse = 1;
                my $unpacker = Data::MessagePack::Unpacker->new;
            
                my $limit = length $$output;
                my $off = 0;
                
                while (1) { #walk through the data, to verify it could be read
                    $off = $unpacker->execute($$output, $off);
                    my $tmp_null = $unpacker->data;
                    $unpacker->reset;
                    last if $off >= $limit;
                }
            
                DEBUG "proc_sysinfo output was unparsed Ok.";
            }
            
            return;
        }

        DEBUG "About to restart proc_sysinfo process, as no valid data received [curr: $curr_attempt / left: $attempts]" if DEBUG_MODE;
        get_check_process('force');
    }

    DEBUG "Error communicating with proc_sysinfo - it didn't send anything after $curr_attempt attempts, about to die." if DEBUG_MODE;
    die "Couldn't read data from proc_sysinfo (gave up after $curr_attempt attempts).";
}


sub report_process_error {
    
    my $output = shift;
    DEBUG "proc_sysinfo reported to the STDERR, collecting information on the issue..." if DEBUG_MODE;
        
    if (is_printable($$output)) {
        die "proc_sysinfo reported an error: $$output";
        
    } else {
        
        DEBUG "Error returned from proc_sysinfo is not a text message, saving binary output." if DEBUG_MODE;
            
        my $filename = $config->{ProcSysInfoDumpName}.'.'.time();
        my $msg = "proc_sysinfo posted non-printable data to the error channel.";
        my $len = dump_binary_data($filename, $$output);
            
        if(defined $len) {
            $msg .= " $len bytes were dumped to $filename.";
            DEBUG "About to die with saved binary output at $filename." if DEBUG_MODE;
        } else {
            $msg .= " Tried to dump output to $filename, but failed: $!";
            DEBUG "Tried to save the dump at $filename, but failed - about to die with the error message: $!." if DEBUG_MODE;
        }
            
        die $msg;
    }
}


sub get_check_process {
    
    my $force = shift;
    my $signal;
    
    if (defined($force) && ($force eq 'force')) {
        WARN "Force (-9) sysinfo module termination initiated (instances counter=$process_instances_counter)";
        $signal = 9;
    } elsif (defined($force) && ($force eq 'term')) {
        WARN "Force (-15) sysinfo module termination initiated (instances counter=$process_instances_counter)" if ($^V gt v5.10.0); #On Perl 5.8 we keep restarting the binary to avoid IPC issues 
        $signal = 15;
    } elsif (defined($force)) {
        die "Requested to kill, but no signal specified";
    }

    if ($force && $pid) {
        
        DEBUG "Force process restart requested, going to 'kill -$signal $pid'... " if DEBUG_MODE;
        
        if (kill($signal, $pid)) {
            DEBUG "Killed successfully" if DEBUG_MODE;
        } else {
            DEBUG "No recipients found..." if DEBUG_MODE;
        }
        
        my $kid = waitpid($pid, 0);
        DEBUG "proc_sysinfo's killed waitpid()=$kid" if DEBUG_MODE;
        
        
        $pid = 0;
        DEBUG "reseting children pid=$pid" if DEBUG_MODE;
    }

    unless ($pid) {
        
        if (($process_instances_counter+1) > $process_instances_limit) {
            DEBUG "Caught a dangerous situation - too many proc_sysinfo's executions ($process_instances_counter out of $process_instances_limit), going to halt." if DEBUG_MODE;
            TenBees::Agent::critical_error("Aborted starting instance of the proc_sysinfo at counter=$process_instances_counter");
        }
        
        DEBUG "There is no proc_sysinfo running for this agent, needs to start one." if DEBUG_MODE;

        undef $stdin;
        undef $stdout;
        undef $stderr;

        $stdin = IO::Handle->new();
        $stdout = IO::Handle->new();
        $stderr = IO::Handle->new();
        
        my $binary;
        
        # open3 throws exception in parent if exec failed in child
        # carefully handle it, cleaning up zombie processes if any
        eval {
            $binary = join '/', ($config->{HomeDir}, $config->{ProcSysInfoDir} , binary_name());
            
            DEBUG "open3() version ".${IPC::TBOpen3::VERSION}." (1.12+ is Ok) for '$binary'." if DEBUG_MODE;
            
            $pid = open3($stdin, $stdout, $stderr, $binary);
            
            binmode($stdin, ':stdio');
            binmode($stdout, ':stdio');
            binmode($stderr, ':stdio');
        };
        
        if($@) {
            ERROR "Failed to start '$binary': $@";
            
            if($pid) {
                #On MacOS X 10.6 and 10.7 manual waitpid() is the best way to go
                DEBUG "Agent verifying clean PID=$pid proc_sysinfo recycling..." if DEBUG_MODE;
                my $kid = waitpid($pid, 0);
                DEBUG "proc_sysinfo's recycling waitpid()=$kid" if DEBUG_MODE;
            }
            
            DEBUG "Setting pid to 0 and returning" if DEBUG_MODE;
            $pid = 0;
            return;
        }
        
        $process_instances_counter++ if ($^V gt v5.10.0);
        DEBUG "proc_sysinfo seems to be started (pid: $pid, counter: $process_instances_counter)" if DEBUG_MODE;
        
        DEBUG "touching $config->{Pid}" if DEBUG_MODE;
        utime (undef, undef, $config->{Pid});
    }
}


sub send_command {
    
    my $command = shift;
    my $res = shift;

    my $config = TenBees::Config->get();
    my $seconds_to_wait_for_ipc = $config->{IPCTimeout};
    
    get_check_process();
    
    DEBUG "Flushing the STDIN, STDOUT, STDERR..." if DEBUG_MODE;
    $stdin->flush;
    $stdout->flush;
    $stderr->flush;
    
    DEBUG "Opening STDIN writing channel.." if DEBUG_MODE;

    my $write_select = IO::Select->new();
    $write_select->add($stdin);

    my @ready = $write_select->can_write($seconds_to_wait_for_ipc);

    unless (@ready) {
        die "Can't open communication flow with sysinfo module for $seconds_to_wait_for_ipc seconds";
    }

    undef $write_select;
    undef @ready;

    DEBUG "Sending '$command' command" if DEBUG_MODE;

    my $rv = -1;
    $rv = syswrite($stdin, $command);
    
    unless (defined $rv && $rv == length($command)) {
        DEBUG "syswrite() has failed, dying now." if DEBUG_MODE; 
        die "Can't send '$command' to the sysinfo module: ".($!||'');
    }
    
    my $nlrv = -1;
    my $nl = "\n";
    $nlrv = syswrite($stdin, $nl);
    
    unless (defined $nlrv && $nlrv == length($nl)) {
        DEBUG "newline syswrite() has failed, dying now." if DEBUG_MODE; 
        die "Can't send newline $nl to the sysinfo module: ".($!||'');
    }
    
    DEBUG "'$command' ($rv bytes) command send." if DEBUG_MODE;

    DEBUG "Opening STDOUT & STDERR channels..." if DEBUG_MODE;
    my $read_select = IO::Select->new();
    $read_select->add($stdout);
    $read_select->add($stderr);

    my %output = (
        $stdout => '',
        $stderr => '',
    );
    
    my $handler = 0;

    my $chunk_size = $config->{ReadChunkSize};

    while ($read_select->count() && (@ready = $read_select->can_read($seconds_to_wait_for_ipc))) {

        $handler = $ready[0];
        
        DEBUG "reading (max $chunk_size bytes chunk) from the 1st handler out of ".scalar(@ready)."..." if DEBUG_MODE;
        
        my $chunk = undef;
        my $rv = sysread($handler, $chunk, $chunk_size);
        
        if ($!) {
            DEBUG "sysread() from proc_sysinfo has failed due to the error: $!" if DEBUG_MODE;
            die "Can't read data from the proc_sysinfo: $!.";
        }
        
        $output{$handler} .= $chunk;
        
        if (!defined $rv) {
            DEBUG "sysread() failed to get anything from proc_sysinfo, dying now." if DEBUG_MODE;
            die "Failed to read anything from the proc_sysinfo: $!";
        }
        
        if (($rv == 0) || ($rv < $chunk_size)) {
            DEBUG "done reading $rv bytes from the proc_sysinfo, moving forward." if DEBUG_MODE;            
            $read_select->remove($handler);
            $read_select = undef;
            last if scalar(@ready) == 1; # avoiding unnecessary select if there was only one source
        }
        
    }
    
    DEBUG "Flushing the STDIN, STDOUT, STDERR..." if DEBUG_MODE;
    $stdin->flush;
    $stdout->flush;
    $stderr->flush;

    if ($output{$stderr}) {
        return report_process_error(\($output{$stderr}));
        
    } elsif ($output{$stdout}) {
        DEBUG "Data read from STDOUT - assumed to be a proper binary output, returning it." if DEBUG_MODE;
        $$res = $output{$stdout};
        return;
        
    } else {
        DEBUG "proc_sysinfo returned nothing at all - nor to the STDOUT, nor to the STDERR, about to die." if DEBUG_MODE;
        die 'No data received from proc_sysinfo.';
    }
}

1;
