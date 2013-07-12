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

package TenBees::Delivery;
use warnings;
use strict;

use base 'Exporter';
use Socket qw/:DEFAULT /;
use Sys::Hostname qw/ hostname /;
use MIME::Base64 qw/ encode_base64 /;
use Digest::SHA qw/ sha1_hex /;

use TenBees::Logger;
use TenBees::Config;

our @EXPORT_OK = qw/ send2collector /;


sub urlencode {
    my $str = shift;
    $str =~ s/([^^A-Za-z0-9\-_.!~*'()])/ sprintf "%%%0x", ord $1 /eg;

    return $str;
}


sub build_action_uri {

    my $action = shift;
    my $opts = shift;
    my $checksum = shift;

    my $config = TenBees::Config->get();

    my $request_uri = '';

    if ($action eq 'put') {
        my $count = $opts->{count} || 1;
        $request_uri = "/".$config->{ProtocolVersion}."/put/".$config->{HostId}."/$checksum/$count";
        
    } elsif ($action eq 'reg') {
        my $quoted_userid = urlencode($opts->{UserId});
        $request_uri = "/".$config->{ProtocolVersion}."/reg/$quoted_userid/$checksum";
        
    } else {
        die "Function called with unknown action request: '$action', leaving.";
    }

    return $request_uri;
}


sub prepare_data {
    
    my $action = shift;
    my $data = shift || undef; # must be reference
    my $opts = shift || {};
    
    DEBUG 'Obtaining collector address' if DEBUG_MODE;
    
    my $config = TenBees::Config->get();

    my $not_enough_info = 0;
    my $diemsg = "Collector's server information is not complete. Can't find the following details: ";

    if(!$config->{Hostname}) {
        $diemsg .= "server hostname ";
        $not_enough_info = 1;
    }
    
    my $inet_aton_host = inet_aton($config->{Hostname});
    if(!$inet_aton_host) {
        die "Can't resolve the hostname to the binary structure ($@).";
    }
    
    if (!$config->{Port}) {
       $diemsg .= "server port ";
       $not_enough_info = 1;
    }
    if(!defined $config->{HostId}) {
       $diemsg .= "host id ";
       $not_enough_info = 1;
    }
    if(!$config->{AuthKey}) {
        $diemsg .= "auth key ";
        $not_enough_info = 1;
    }

    die $diemsg if $not_enough_info;

    my $server_info = {
        'hostname' => $config->{Hostname},
        'inet_aton_host' => $inet_aton_host,
        'port' => $config->{Port},
    };

    DEBUG "Collector coordinates: $server_info->{hostname}:$server_info->{port}, auth: $config->{HostId} / $config->{AuthKey}." if DEBUG_MODE;
    
    my $checksum = sha1_hex($config->{AuthKey}.':'.$$data);
    my $data_length = length($$data);

    return($server_info, $checksum, $data_length);
}


sub try_send {

    my $data_to_send = shift;
    my $result = shift;

    my $server_info = $data_to_send->{server_info};

    my $headers = {
        'Content-Length' => $data_to_send->{data_length},
    };

    local $/ = undef;

    socket(
        SOCK,
        PF_INET,
        SOCK_STREAM,
        getprotobyname('tcp')
    ) or die "Can't open socket: $!";

    connect(
        SOCK,
        sockaddr_in($server_info->{port}, $server_info->{inet_aton_host})
    ) or die "Can not establish the connection to the remote server: $!";

    select(SOCK);
    $| = 1;
    select(STDOUT);

    DEBUG "Socket opened, connection established, buffering disabled." if DEBUG_MODE;

    my $push = join "\015\012",
        'POST '.$data_to_send->{URI}.' HTTP/1.0',
        'Host: '.$server_info->{hostname},
        (map { "$_: $headers->{$_}" if $_ } keys %{$headers}),
        '',
        ${$data_to_send->{data}};

    DEBUG "Sending data to the socket..." if DEBUG_MODE;
    print SOCK $push;
        
    DEBUG 'Data wrote to the socket successfully, waiting for the reply...' if DEBUG_MODE;
    @{$result} = <SOCK>;

    DEBUG 'Answer received, closing socket...' if DEBUG_MODE;
    close SOCK
	or die "Can't close collector socket: $!";
    
    return 1;
}


sub try_send_throw_proxy {

    my $data_to_send = shift;
    my $result = shift;

    my $server_info = $data_to_send->{server_info};
    
    my $URI = 'http://' . $server_info->{hostname} 
        . ':' . $server_info->{port}
        . '/' . $data_to_send->{URI};

    my $config = TenBees::Config->get();
    
    require HTTP::Lite;

    my $http_client = HTTP::Lite->new();

    my $proxy = undef;

    if($config->{ProxyHost}) {
        $proxy .= $config->{ProxyHost};
    }

    if($config->{ProxyPort}) {
        $proxy .= ':' . $config->{ProxyPort};
    }
    
    $http_client->proxy($proxy);

    $http_client->{content_type} = undef;
    $http_client->{content_length} = $data_to_send->{data_length};
    $http_client->{method} = 'POST';
    $http_client->{content} = ${$data_to_send->{data}};
    $http_client->{RAW} = 1;

    my $request = $http_client->request($URI) or die "HTTP request failed: $!";

    @{$result} = $request;

    return 1;
}


sub send2collector {
    
    my $action = $_[0];
    my $data = $_[1] || undef; #must be a reference
    my $opts = $_[2] || {};
    
    DEBUG 'Sending data to the collector' if DEBUG_MODE;
    
    my $config = TenBees::Config->get();

    if ($action eq 'reg') {$config->{HostId} = -1;} #address data verification pass with non-registered host
    
    my ($server_info, $checksum, $data_length);
    
    eval {
	($server_info, $checksum, $data_length) = prepare_data(@_);
	DEBUG "Getting ready to send $data_length characters long data with checksum = $checksum." if DEBUG_MODE;
    };
    
    if ($@) {
        CRITICAL "Can't resolve the DNS name / create a URL to use: ".$@;
        return ['Critical error at Delivery.pm'];
    }

    my $request_uri = build_action_uri($action, $opts, $checksum);
    DEBUG "Delivery URL composed: '$request_uri'." if DEBUG_MODE;

    my $result = [];

    my $data_to_send = {
        server_info => $server_info,
        data => $data,
        data_length => $data_length,
        URI => $request_uri,
    };

    eval {
        local $SIG{ALRM} = sub {
	    die "Failed to deliver data to the collector withing $config->{ServerTimeOut} seconds time limit"
	};
        
	alarm ($config->{ServerTimeOut});
    
        DEBUG "About to send data to the server, with timeout up to $config->{ServerTimeOut} seconds" if DEBUG_MODE;
        $config->{ProxyHost} ? try_send_throw_proxy($data_to_send, $result) : try_send($data_to_send, $result);
    
        alarm 0;
    
        DEBUG "Communication completed successfully." if DEBUG_MODE;

    };

    alarm 0;

    if ($@) {
        CRITICAL 'Communication has failed: '.$@;
        $result->[0] = 'Local error: '.$@;
    }

    return $result;
}

1;
