package PVE::AbstractMigrate;

use strict;
use warnings;
use POSIX qw(strftime);
use JSON;
use PVE::Tools;
use PVE::Cluster;
use PVE::ReplicationState;

my $msg2text = sub {
    my ($level, $msg) = @_;

    chomp $msg;

    return '' if !$msg;

    my $res = '';

    my $tstr = strftime("%F %H:%M:%S", localtime);

    foreach my $line (split (/\n/, $msg)) {
	if ($level eq 'err') {
	    $res .= "$tstr ERROR: $line\n";
	} else {
	    $res .= "$tstr $line\n";
	}
    }

    return $res;
};

sub log {
    my ($self, $level, $msg) = @_;

    chomp $msg;

    return if !$msg;

    print &$msg2text($level, $msg);
}

sub cmd {
    my ($self, $cmd, %param) = @_;

    my $logfunc = sub {
	my $line = shift;
	$self->log('info', $line);
    };

    $self->log('info', "# " . PVE::Tools::cmd2string($cmd));

    PVE::Tools::run_command($cmd, %param, outfunc => $logfunc, errfunc => $logfunc);
}

my $run_command_quiet_full = sub {
    my ($self, $cmd, $logerr, %param) = @_;

    my $log = '';
    my $logfunc = sub {
	my $line = shift;
	$log .= &$msg2text('info', $line);;
    };

    eval { PVE::Tools::run_command($cmd, %param, outfunc => $logfunc, errfunc => $logfunc); };
    if (my $err = $@) {
	$self->log('info', "# " . PVE::Tools::cmd2string($cmd));
	print $log;
	if ($logerr) {
	    $self->{errors} = 1;
	    $self->log('err', $err);
	} else {
	    die $err;
	}
    }
};

sub cmd_quiet {
    my ($self, $cmd, %param) = @_;
    return &$run_command_quiet_full($self, $cmd, 0, %param);
}

sub cmd_logerr {
    my ($self, $cmd, %param) = @_;
    return &$run_command_quiet_full($self, $cmd, 1, %param);
}

my $eval_int = sub {
    my ($self, $func, @param) = @_;

    eval {
	local $SIG{INT} =
	    local $SIG{TERM} =
	    local $SIG{QUIT} =
	    local $SIG{HUP} =
	    local $SIG{PIPE} = sub {
		$self->{delayed_interrupt} = 0;
		die "interrupted by signal\n";
	};

	my $di = $self->{delayed_interrupt};
	$self->{delayed_interrupt} = 0;

	die "interrupted by signal\n" if $di;

	&$func($self, @param);
    };
};

# FIXME: nodeip is now unused
sub migrate {
    my ($class, $node, $nodeip, $vmid, $opts) = @_;

    $class = ref($class) || $class;

    my $dc_conf = PVE::Cluster::cfs_read_file('datacenter.cfg');

    my $migration_network = $opts->{migration_network};
    if (!defined($migration_network)) {
	$migration_network = $dc_conf->{migration}->{network};
    }
    my $ssh_info = PVE::Cluster::get_ssh_info($node, $migration_network);
    $nodeip = $ssh_info->{ip};

    my $migration_type = 'secure';
    if (defined($opts->{migration_type})) {
	$migration_type = $opts->{migration_type};
    } elsif (defined($dc_conf->{migration}->{type})) {
        $migration_type = $dc_conf->{migration}->{type};
    }
    $opts->{migration_type} = $migration_type;

    my $self = {
	delayed_interrupt => 0,
	opts => $opts,
	vmid => $vmid,
	node => $node,
	ssh_info => $ssh_info,
	nodeip => $nodeip,
	rem_ssh => PVE::Cluster::ssh_info_to_command($ssh_info)
    };

    $self = bless $self, $class;

    my $starttime = time();

    local $SIG{INT} =
	local $SIG{TERM} =
	local $SIG{QUIT} =
	local $SIG{HUP} =
	local $SIG{PIPE} = sub {
	    $self->log('err', "received interrupt - delayed");
	    $self->{delayed_interrupt} = 1;
    };

    # lock container during migration
    eval { $self->lock_vm($self->{vmid}, sub {

	$self->{running} = 0;
	&$eval_int($self, sub { $self->{running} = $self->prepare($self->{vmid}); });
	die $@ if $@;

	if (defined($migration_network)) {
	    $self->log('info', "use dedicated network address for sending " .
	               "migration traffic ($self->{nodeip})");

	    # test if we can connect to new IP
	    my $cmd = [ @{$self->{rem_ssh}}, '/bin/true' ];
	    eval { $self->cmd_quiet($cmd); };
	    die "Can't connect to destination address ($self->{nodeip}) using " .
	        "public key authentication\n" if $@;
	}

	&$eval_int($self, sub { $self->phase1($self->{vmid}); });
	my $err = $@;
	if ($err) {
	    $self->log('err', $err);
	    eval { $self->phase1_cleanup($self->{vmid}, $err); };
	    if (my $tmperr = $@) {
		$self->log('err', $tmperr);
	    }
	    eval { $self->final_cleanup($self->{vmid}); };
	    if (my $tmperr = $@) {
		$self->log('err', $tmperr);
	    }
	    die $err;
	}

	# vm is now owned by other node
	# Note: there is no VM config file on the local node anymore

	if ($self->{running}) {

	    &$eval_int($self, sub { $self->phase2($self->{vmid}); });
	    my $phase2err = $@;
	    if ($phase2err) {
		$self->{errors} = 1;
		$self->log('err', "online migrate failure - $phase2err");
	    }
	    eval { $self->phase2_cleanup($self->{vmid}, $phase2err); };
	    if (my $err = $@) {
		$self->log('err', $err);
		$self->{errors} = 1;
	    }
	}

	# phase3 (finalize) 
	&$eval_int($self, sub { $self->phase3($self->{vmid}); });
	my $phase3err = $@;
	if ($phase3err) {
	    $self->log('err', $phase3err);
	    $self->{errors} = 1;
	}
	eval { $self->phase3_cleanup($self->{vmid}, $phase3err); };
	if (my $err = $@) {
	    $self->log('err', $err);
	    $self->{errors} = 1;
	}
	eval { $self->final_cleanup($self->{vmid}); };
	if (my $err = $@) {
	    $self->log('err', $err);
	    $self->{errors} = 1;
	}
    })};

    my $err = $@;

    my $delay = time() - $starttime;
    my $mins = int($delay/60);
    my $secs = $delay - $mins*60;
    my $hours =  int($mins/60);
    $mins = $mins - $hours*60;

    my $duration = sprintf "%02d:%02d:%02d", $hours, $mins, $secs;

    if ($err) {
	$self->log('err', "migration aborted (duration $duration): $err");
	die "migration aborted\n";
    }

    if ($self->{errors}) {
	$self->log('err', "migration finished with problems (duration $duration)");
	die "migration problems\n"
    }

    $self->log('info', "migration finished successfully (duration $duration)");
}

sub lock_vm {
    my ($self, $vmid, $code, @param) = @_;

    die "abstract method - implement me";
}

sub prepare {
    my ($self, $vmid) = @_;

    die "abstract method - implement me";

    # return $running;
}

# transfer all data and move VM config files
sub phase1 {
    my ($self, $vmid) = @_;
    die "abstract method - implement me";
}

# only called if there are errors in phase1
sub phase1_cleanup {
    my ($self, $vmid, $err) = @_;
    die "abstract method - implement me";
}

# only called when VM is running and phase1 was successful
sub phase2 {
    my ($self, $vmid) = @_;
    die "abstract method - implement me";
}

# only called when VM is running and phase1 was successful
sub phase2_cleanup {
    my ($self, $vmid, $err) = @_;
};

#  only called when phase1 was successful
sub phase3 {
    my ($self, $vmid) = @_;
}

#  only called when phase1 was successful
sub phase3_cleanup {
    my ($self, $vmid, $err) = @_;
}

# final cleanup - always called
sub final_cleanup {
    my ($self, $vmid) = @_;
    die "abstract method - implement me";
}

# transfer replication state helper - call this before moving the guest config
# - just log the error is something fails
sub transfer_replication_state {
    my ($self) = @_;

    my $local_node = PVE::INotify::nodename();

    eval {
	my $stateobj = PVE::ReplicationState::read_state();
	my $vmstate = PVE::ReplicationState::extract_vmid_tranfer_state($stateobj, $self->{vmid}, $self->{node}, $local_node);
	# This have to be quoted when it run it over ssh.
	my $state = PVE::Tools::shellquote(encode_json($vmstate));
	my $cmd = [ @{$self->{rem_ssh}}, 'pvesr', 'set-state', $self->{vmid}, $state];
	$self->cmd($cmd);
    };
    if (my $err = $@) {
	$self->log('err', "transfer replication state failed - $err");
	$self->{errors} = 1;
    }
}

# switch replication job target - call this after moving the guest config
# - does nothing if there is no relevant replication job
# - just log the error is something fails
sub switch_replication_job_target {
    my ($self) = @_;

    my $local_node = PVE::INotify::nodename();

    eval { PVE::ReplicationConfig::switch_replication_job_target($self->{vmid}, $self->{node}, $local_node); };
    if (my $err = $@) {
	$self->log('err', "switch replication job target failed - $err");
	$self->{errors} = 1;
    }
}

1;
