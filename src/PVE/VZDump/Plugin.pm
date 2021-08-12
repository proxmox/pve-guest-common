package PVE::VZDump::Plugin;

use strict;
use warnings;

use POSIX qw(strftime);

use PVE::Tools;
use PVE::SafeSyslog;
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use PVE::VZDump::Common; # register parser/writer for vzdump.cron

my $log_level = {
    err =>  'ERROR:',
    info => 'INFO:',
    warn => 'WARN:',
};

sub debugmsg {
    my ($mtype, $msg, $logfd, $syslog) = @_;

    chomp $msg;

    return if !$msg;

    my $level = $log_level->{$mtype} ? $mtype : 'err';
    my $pre = $log_level->{$level};

    my $timestr = strftime ("%F %H:%M:%S", CORE::localtime);

    syslog ($level, "$pre $msg") if $syslog;

    foreach my $line (split (/\n/, $msg)) {
	print STDERR "$pre $line\n";
	print $logfd "$timestr $pre $line\n" if $logfd;
    }
}

sub set_logfd {
    my ($self, $logfd) = @_;

    $self->{logfd} = $logfd;
}

sub cmd {
    my ($self, $cmdstr, %param) = @_;

    my $logfunc = sub {
	my $line = shift;
	debugmsg ('info', $line, $self->{logfd});
    };

    PVE::Tools::run_command($cmdstr, %param, logfunc => $logfunc);
}

sub cmd_noerr {
    my ($self, $cmdstr, %param) = @_;

    my $res;
    eval { $res = $self->cmd($cmdstr, %param); };
    $self->logerr ($@) if $@;
    return $res;
}

sub log {
    my ($self, $level, $msg, $to_syslog) = @_;

    debugmsg($level, $msg, $self->{logfd}, $to_syslog);
}

sub loginfo {
    my ($self, $msg) = @_;

    debugmsg('info', $msg, $self->{logfd}, 0);
}

sub logerr {
    my ($self, $msg) = @_;

    debugmsg('err', $msg, $self->{logfd}, 0);
}

sub type {
    return 'unknown';
};

sub vmlist {
    my ($self) = @_;

    return [ keys %{$self->{vmlist}} ] if $self->{vmlist};

    return [];
}

sub vm_status {
    my ($self, $vmid) = @_;

    die "internal error"; # implement in subclass
}

sub prepare {
    my ($self, $task, $vmid, $mode) = @_;

    die "internal error"; # implement in subclass
}

sub lock_vm {
    my ($self, $vmid) = @_;

    die "internal error"; # implement in subclass
}

sub unlock_vm {
    my ($self, $vmid) = @_;

    die "internal error"; # implement in subclass
}

sub stop_vm {
    my ($self, $task, $vmid) = @_;

    die "internal error"; # implement in subclass
}

sub start_vm {
    my ($self, $task, $vmid) = @_;

    die "internal error"; # implement in subclass
}

sub suspend_vm {
    my ($self, $task, $vmid) = @_;

    die "internal error"; # implement in subclass
}

sub resume_vm {
    my ($self, $task, $vmid) = @_;

    die "internal error"; # implement in subclass
}

sub snapshot {
    my ($self, $task, $vmid) = @_;

    die "internal error"; # implement in subclass
}

sub copy_data_phase2 {
    my ($self, $task, $vmid) = @_;

    die "internal error"; # implement in subclass
}

sub assemble {
    my ($self, $task, $vmid) = @_;

    die "internal error"; # implement in subclass
}

sub archive {
    my ($self, $task, $vmid, $filename, $comp) = @_;

    die "internal error"; # implement in subclass
}

sub cleanup {
    my ($self, $task, $vmid) = @_;

    die "internal error"; # implement in subclass
}

sub remove_vmid_from_list {
    my ($list, $rm_vmid) = @_;
    # this removes the given vmid from the list, if present
    return join(',', grep { $_ ne $rm_vmid } PVE::Tools::split_list($list));
}

sub remove_vmid_from_jobs {
    my ($jobs, $exclude_vmid) = @_;

    my $updated_jobs = [];
    foreach my $job (@$jobs) {
	if (defined $job->{vmid}) {
	    my $list = remove_vmid_from_list($job->{vmid}, $exclude_vmid);
	    if ($list) {
		$job->{vmid} = $list;
		push @$updated_jobs, $job;
	    }
	} elsif (defined $job->{exclude}) {
	    my $list = remove_vmid_from_list($job->{exclude}, $exclude_vmid);
	    if ($list) {
		$job->{exclude} = $list;
	    } else {
		delete $job->{exclude};
	    }
	    push @$updated_jobs, $job;
	} else {
	    push @$updated_jobs, $job;
	}
    }
    return $updated_jobs;
}

sub remove_vmid_from_backup_jobs {
    my ($vmid) = @_;

    cfs_lock_file('vzdump.cron', undef, sub {
	my $vzdump_jobs = cfs_read_file('vzdump.cron');
	my $jobs = $vzdump_jobs->{jobs} || [];
	$vzdump_jobs->{jobs} = remove_vmid_from_jobs($jobs, $vmid);
	cfs_write_file('vzdump.cron', $vzdump_jobs);
    });
    die "$@" if ($@);
}

1;