package PVE::ReplicationState;

use warnings;
use strict;
use JSON;

use PVE::INotify;
use PVE::Tools;
use PVE::CalendarEvent;
use PVE::Cluster;
use PVE::GuestHelpers;
use PVE::ReplicationConfig;

# Note: regression tests can overwrite $state_path for testing
our $state_path = "/var/lib/pve-manager/pve-replication-state.json";
our $state_lock = "/var/lib/pve-manager/pve-replication-state.lck";
our $replicate_logdir = "/var/log/pve/replicate";

# regression tests should overwrite this
sub job_logfile_name {
    my ($jobid) = @_;

    return "${replicate_logdir}/$jobid";
}

# Note: We use PVE::Tools::file_set_contents to write state file atomically,
# so read_state() always returns an consistent copy (even when not locked).

sub read_state {

    return {} if ! -e $state_path;

    my $raw = PVE::Tools::file_get_contents($state_path);

    return {} if $raw eq '';

    # untaint $raw
    if ($raw =~ m/^({.*})$/) {
	return decode_json($1);
    }

    die "invalid json data in '$state_path'\n";
}

sub extract_job_state {
    my ($stateobj, $jobcfg) = @_;

    my $plugin = PVE::ReplicationConfig->lookup($jobcfg->{type});

    my $vmid = $jobcfg->{guest};
    my $tid = $plugin->get_unique_target_id($jobcfg);
    my $state = $stateobj->{$vmid}->{$tid};

    $state = {} if !$state;

    $state->{last_iteration} //= 0;
    $state->{last_try} //= 0; # last sync start time
    $state->{last_sync} //= 0; # last successful sync start time
    $state->{fail_count} //= 0;

    return $state;
}

sub read_job_state {
    my ($jobcfg) = @_;

    my $stateobj = read_state();
    return extract_job_state($stateobj, $jobcfg);
}

sub write_job_state {
    my ($jobcfg, $state) = @_;

    my $plugin = PVE::ReplicationConfig->lookup($jobcfg->{type});

    my $vmid = $jobcfg->{guest};
    my $tid = $plugin->get_unique_target_id($jobcfg);

    my $update = sub {

	my $stateobj = read_state();
	# Note: tuple ($vmid, $tid) is unique
	$stateobj->{$vmid}->{$tid} = $state;

	PVE::Tools::file_set_contents($state_path, encode_json($stateobj));
    };

    my $code = sub {
	PVE::Tools::lock_file($state_lock, 10, $update);
	die $@ if $@;
    };

    # make sure we have guest_migration_lock during update
    PVE::GuestHelpers::guest_migration_lock($vmid, undef, $code);
}

sub replication_snapshot_name {
    my ($jobid, $last_sync) = @_;

    my $prefix = "__replicate_${jobid}_";
    my $snapname = "${prefix}${last_sync}__";

    wantarray ? ($prefix, $snapname) : $snapname;
}

sub job_status {

    my $local_node = PVE::INotify::nodename();

    my $jobs = {};

    my $stateobj = read_state();

    my $cfg = PVE::ReplicationConfig->new();

    my $vms = PVE::Cluster::get_vmlist();

    foreach my $jobid (sort keys %{$cfg->{ids}}) {
	my $jobcfg = $cfg->{ids}->{$jobid};
	my $vmid = $jobcfg->{guest};

	die "internal error - not implemented" if $jobcfg->{type} ne 'local';

	# skip non existing vms
	next if !$vms->{ids}->{$vmid};

	# only consider guest on local node
	next if $vms->{ids}->{$vmid}->{node} ne $local_node;

	if (!$jobcfg->{remove_job}) {
	    # never sync to local node
	    next if $jobcfg->{target} eq $local_node;

	    next if $jobcfg->{disable};
	}

	my $state = extract_job_state($stateobj, $jobcfg);
	$jobcfg->{state} = $state;
	$jobcfg->{id} = $jobid;
	$jobcfg->{vmtype} = $vms->{ids}->{$vmid}->{type};

	my $next_sync = 0;

	if ($jobcfg->{remove_job}) {
	    $next_sync = 1; # lowest possible value
	    # todo: consider fail_count? How many retries?
	} else  {
	    if (my $fail_count = $state->{fail_count}) {
		if ($fail_count < 3) {
		    $next_sync = $state->{last_try} + 5*60*$fail_count;
		}
	    } else {
		my $schedule =  $jobcfg->{schedule} || '*/15';
		my $calspec = PVE::CalendarEvent::parse_calendar_event($schedule);
		$next_sync = PVE::CalendarEvent::compute_next_event($calspec, $state->{last_try}) // 0;
	    }
	}

	$jobcfg->{next_sync} = $next_sync;

	$jobs->{$jobid} = $jobcfg;
    }

    return $jobs;
}

sub get_next_job {
    my ($iteration, $start_time) = @_;

    my $jobs = job_status();

    my $sort_func = sub {
	my $joba = $jobs->{$a};
	my $jobb = $jobs->{$b};
	my $sa =  $joba->{state};
	my $sb =  $jobb->{state};
	my $res = $sa->{last_iteration} cmp $sb->{last_iteration};
	return $res if $res != 0;
	$res = $joba->{next_sync} <=> $jobb->{next_sync};
	return $res if $res != 0;
	return  $joba->{guest} <=> $jobb->{guest};
    };

    foreach my $jobid (sort $sort_func keys %$jobs) {
	my $jobcfg = $jobs->{$jobid};
	next if $jobcfg->{state}->{last_iteration} >= $iteration;
	if ($jobcfg->{next_sync} && ($start_time >= $jobcfg->{next_sync})) {
	    return $jobcfg;
	}
    }

    return undef;
}

1;