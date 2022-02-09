package PVE::Tunnel;

use strict;
use warnings;

use IO::Pipe;
use IPC::Open2;
use JSON qw(encode_json decode_json);
use POSIX qw( WNOHANG );
use Storable qw(dclone);
use URI::Escape;

use PVE::APIClient::LWP;
use PVE::Tools;

my $finish_command_pipe = sub {
    my ($cmdpipe, $timeout) = @_;

    my $cpid = $cmdpipe->{pid};
    return if !defined($cpid);

    my $writer = $cmdpipe->{writer};
    my $reader = $cmdpipe->{reader};

    $writer->close();
    $reader->close();

    my $collect_child_process = sub {
	my $res = waitpid($cpid, WNOHANG);
	if (defined($res) && ($res == $cpid)) {
	    delete $cmdpipe->{cpid};
	    return 1;
	} else {
	    return 0;
	}
    };

    if ($timeout) {
	for (my $i = 0; $i < $timeout; $i++) {
	    return if &$collect_child_process();
	    sleep(1);
	}
    }

    $cmdpipe->{log}->('info', "tunnel still running - terminating now with SIGTERM\n");
    kill(15, $cpid);

    # wait again
    for (my $i = 0; $i < 10; $i++) {
	return if &$collect_child_process();
	sleep(1);
    }

    $cmdpipe->{log}->('info', "tunnel still running - terminating now with SIGKILL\n");
    kill 9, $cpid;
    sleep 1;

    $cmdpipe->{log}->('err', "tunnel child process (PID $cpid) couldn't be collected\n")
	if !&$collect_child_process();
};

sub read_tunnel {
    my ($tunnel, $timeout) = @_;

    $timeout = 60 if !defined($timeout);

    my $reader = $tunnel->{reader};

    my $output;
    eval {
	PVE::Tools::run_with_timeout($timeout, sub { $output = <$reader>; });
    };
    die "reading from tunnel failed: $@\n" if $@;

    chomp $output if defined($output);

    return $output;
}

sub write_tunnel {
    my ($tunnel, $timeout, $command, $params) = @_;

    $timeout = 60 if !defined($timeout);

    my $writer = $tunnel->{writer};

    if ($tunnel->{version} && $tunnel->{version} >= 2) {
	my $object = defined($params) ? dclone($params) : {};
	$object->{cmd} = $command;

	$command = eval { JSON::encode_json($object) };

	die "failed to encode command as JSON - $@\n"
	    if $@;
    }

    eval {
	PVE::Tools::run_with_timeout($timeout, sub {
	    print $writer "$command\n";
	    $writer->flush();
	});
    };
    die "writing to tunnel failed: $@\n" if $@;

    if ($tunnel->{version} && $tunnel->{version} >= 1) {
	my $res = eval { read_tunnel($tunnel, $timeout); };
	die "no reply to command '$command': $@\n" if $@;

	if ($tunnel->{version} == 1) {
	    if ($res eq 'OK') {
		return;
	    } else {
		die "tunnel replied '$res' to command '$command'\n";
	    }
	} else {
	    my $parsed = eval { JSON::decode_json($res) };
	    die "failed to decode tunnel reply '$res' (command '$command') - $@\n"
		if $@;

	    if (!$parsed->{success}) {
		if (defined($parsed->{msg})) {
		    die "error - tunnel command '$command' failed - $parsed->{msg}\n";
		} else {
		    die "error - tunnel command '$command' failed\n";
		}
	    }

	    return $parsed;
	}
    }
}

sub fork_ssh_tunnel {
    my ($rem_ssh, $cmd, $ssh_forward_info, $log) = @_;

    my @localtunnelinfo = ();
    foreach my $addr (@$ssh_forward_info) {
	push @localtunnelinfo, '-L', $addr;
    }

    my $full_cmd = [@$rem_ssh, '-o ExitOnForwardFailure=yes', @localtunnelinfo, @$cmd];

    my $reader = IO::File->new();
    my $writer = IO::File->new();

    my $orig_pid = $$;

    my $cpid;

    eval { $cpid = open2($reader, $writer, @$full_cmd); };

    my $err = $@;

    # catch exec errors
    if ($orig_pid != $$) {
	$log->('err', "can't fork command pipe, aborting\n");
	POSIX::_exit(1);
	kill('KILL', $$);
    }

    die $err if $err;

    my $tunnel = {
	writer => $writer,
	reader => $reader,
	pid => $cpid,
	rem_ssh => $rem_ssh,
	log => $log,
    };

    eval {
	my $helo = read_tunnel($tunnel, 60);
	die "no reply\n" if !$helo;
	die "no quorum on target node\n" if $helo =~ m/^no quorum$/;
	die "got strange reply from tunnel ('$helo')\n"
	    if $helo !~ m/^tunnel online$/;
    };
    $err = $@;

    eval {
	my $ver = read_tunnel($tunnel, 10);
	if ($ver =~ /^ver (\d+)$/) {
	    $tunnel->{version} = $1;
	    $log->('info', "ssh tunnel $ver\n");
	} else {
	    $err = "received invalid tunnel version string '$ver'\n" if !$err;
	}
    };

    if ($err) {
	$finish_command_pipe->($tunnel);
	die "can't open tunnel - $err";
    }
    return $tunnel;
}

sub forward_unix_socket {
    my ($tunnel, $local, $remote) = @_;

    my $params = dclone($tunnel->{params});
    $params->{unix} = $local;
    $params->{url} = $params->{url} ."socket=".uri_escape($remote)."&";
    $params->{ticket} = { path => $remote };

    my $cmd = encode_json({
	control => JSON::true,
	cmd => 'forward',
	data => $params,
    });

    my $writer = $tunnel->{writer};
    $tunnel->{forwarded}->{$local} = $remote;
    eval {
	unlink $local;
	PVE::Tools::run_with_timeout(15, sub {
	    print $writer "$cmd\n";
	    $writer->flush();
	});
    };
    die "failed to write forwarding command - $@\n" if $@;

    read_tunnel($tunnel);
}

sub fork_websocket_tunnel {
    my ($conn, $url, $req_params, $tunnel_params, $log) = @_;

    if (my $apitoken = $conn->{apitoken}) {
	$tunnel_params->{headers} = [["Authorization", "$apitoken"]];
    } else {
	die "can't connect to remote host without credentials\n";
    }

    if (my $fps = $conn->{cached_fingerprints}) {
	$tunnel_params->{fingerprint} = (keys %$fps)[0];
    }

    my $api_client = PVE::APIClient::LWP->new(%$conn);

    my $res = $api_client->post(
	$url,
	$req_params,
    );

    $log->('info', "remote: started tunnel worker '$res->{upid}'");

    my $websocket_url = $tunnel_params->{url};

    $tunnel_params->{url} .= "?ticket=".uri_escape($res->{ticket});
    $tunnel_params->{url} .= "&socket=".uri_escape($res->{socket});

    my $reader = IO::Pipe->new();
    my $writer = IO::Pipe->new();

    my $cpid = fork();
    if ($cpid) {
	$writer->writer();
	$reader->reader();
	my $tunnel = {
	    writer => $writer,
	    reader => $reader,
	    pid => $cpid,
	    log => $log,
	};

	eval {
	    my $writer = $tunnel->{writer};
	    my $cmd = encode_json({
		control => JSON::true,
		cmd => 'connect',
		data => $tunnel_params,
	    });

	    eval {
		PVE::Tools::run_with_timeout(15, sub {
		    print {$writer} "$cmd\n";
		    $writer->flush();
		});
	    };
	    die "failed to write tunnel connect command - $@\n" if $@;
	};
	die "failed to connect via WS: $@\n" if $@;

	my $err;
        eval {
	    my $writer = $tunnel->{writer};
	    my $cmd = encode_json({
		cmd => 'version',
	    });

	    eval {
		PVE::Tools::run_with_timeout(15, sub {
		    print {$writer} "$cmd\n";
		    $writer->flush();
		});
	    };
	    $err = "failed to write tunnel version command - $@\n" if $@;
	    my $res = read_tunnel($tunnel, 10);
	    $res = JSON::decode_json($res);
	    my $version = $res->{api};

	    if ($version =~ /^(\d+)$/) {
		$tunnel->{version} = $1;
		$tunnel->{age} = $res->{age};
	    } else {
		$err = "received invalid tunnel version string '$version'\n" if !$err;
	    }
	};
	$err = $@ if !$err;

	if ($err) {
	    $finish_command_pipe->($tunnel);
	    die "can't open tunnel - $err";
	}

	$tunnel_params->{url} = "$websocket_url?"; # reset ticket and socket

	$tunnel->{params} = $tunnel_params; # for forwarding

	return $tunnel;
    } else {
	eval {
	    $writer->reader();
	    $reader->writer();
	    PVE::Tools::run_command(
		['proxmox-websocket-tunnel'],
		input => "<&".fileno($writer),
		output => ">&".fileno($reader),
		errfunc => sub { my $line = shift; print "tunnel: $line\n"; },
	    );
	};
	warn "CMD websocket tunnel died: $@\n" if $@;
	exit 0;
    }
}

sub finish_tunnel {
    my ($tunnel, $cleanup) = @_;

    $cleanup = $cleanup ? 1 : 0;

    eval { write_tunnel($tunnel, 30, 'quit', { cleanup => $cleanup }); };
    my $err = $@;

    $finish_command_pipe->($tunnel, 30);

    if (my $unix_sockets = $tunnel->{unix_sockets}) {
	# ssh does not clean up on local host
	my $cmd = ['rm', '-f', @$unix_sockets];
	PVE::Tools::run_command($cmd);

	# .. and just to be sure check on remote side
	if ($tunnel->{rem_ssh}) {
	    unshift @{$cmd}, @{$tunnel->{rem_ssh}};
	    PVE::Tools::run_command($cmd);
	}
    }

    die $err if $err;
}
