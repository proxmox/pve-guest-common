package PVE::VZDump::Plugin;

use strict;
use warnings;

use POSIX qw(strftime);

use PVE::Tools;
use PVE::SafeSyslog;

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

1;
