package PVE::ReplicationState;

use warnings;
use strict;
use JSON;

use PVE::INotify;
use PVE::ProcFSTools;
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

sub extract_vmid_tranfer_state {
    my ($stateobj, $vmid, $old_target, $new_target) = @_;

    my $oldid = PVE::ReplicationConfig::Cluster->get_unique_target_id({ target => $old_target });
    my $newid = PVE::ReplicationConfig::Cluster->get_unique_target_id({ target => $new_target });

    if (defined(my $vmstate = $stateobj->{$vmid})) {
	$vmstate->{$newid} = delete($vmstate->{$oldid}) if defined($vmstate->{$oldid});
	return $vmstate;
    }

    return {};
}

sub read_job_state {
    my ($jobcfg) = @_;

    my $stateobj = read_state();
    return extract_job_state($stateobj, $jobcfg);
}

# update state for a single job
# pass $state = undef to delete the job state completely
sub write_job_state {
    my ($jobcfg, $state) = @_;

    my $plugin = PVE::ReplicationConfig->lookup($jobcfg->{type});

    my $vmid = $jobcfg->{guest};
    my $tid = $plugin->get_unique_target_id($jobcfg);

    my $update = sub {

	my $stateobj = read_state();
	# Note: tuple ($vmid, $tid) is unique
	if (defined($state)) {
	    $stateobj->{$vmid}->{$tid} = $state;
	} else {
	    delete $stateobj->{$vmid}->{$tid};
	    delete $stateobj->{$vmid} if !%{$stateobj->{$vmid}};
	}
	PVE::Tools::file_set_contents($state_path, encode_json($stateobj));
    };

    my $code = sub {
	PVE::Tools::lock_file($state_lock, 10, $update);
	die $@ if $@;
    };

    # make sure we have guest_migration_lock during update
    PVE::GuestHelpers::guest_migration_lock($vmid, undef, $code);
}

# update all job states related to a specific $vmid
sub write_vmid_job_states {
    my ($vmid_state, $vmid) = @_;

    my $update = sub {
	my $stateobj = read_state();
	$stateobj->{$vmid} = $vmid_state;
	PVE::Tools::file_set_contents($state_path, encode_json($stateobj));
    };

    my $code = sub {
	PVE::Tools::lock_file($state_lock, 10, $update);
	die $@ if $@;
    };

    # make sure we have guest_migration_lock during update
    PVE::GuestHelpers::guest_migration_lock($vmid, undef, $code);
}

sub record_job_start {
    my ($jobcfg, $state, $start_time, $iteration) = @_;

    $state->{pid} = $$;
    $state->{ptime} = PVE::ProcFSTools::read_proc_starttime($state->{pid});
    $state->{last_node} = PVE::INotify::nodename();
    $state->{last_try} = $start_time;
    $state->{last_iteration} = $iteration;
    $state->{storeid_list} //= [];

    write_job_state($jobcfg, $state);
}

sub delete_guest_states {
    my ($vmid) = @_;

    my $code = sub {
	my $stateobj = read_state();
	delete $stateobj->{$vmid};
	PVE::Tools::file_set_contents($state_path, encode_json($stateobj));
    };

    PVE::Tools::lock_file($state_lock, 10, $code);
}

sub record_job_end {
    my ($jobcfg, $state, $start_time, $duration, $err) = @_;

    $state->{duration} = $duration;
    delete $state->{pid};
    delete $state->{ptime};

    if ($err) {
	chomp $err;
	$state->{fail_count}++;
	$state->{error} = "$err";
	write_job_state($jobcfg,  $state);
    } else {
	if ($jobcfg->{remove_job}) {
	    write_job_state($jobcfg, undef);
	} else {
	    $state->{last_sync} = $start_time;
	    $state->{fail_count} = 0;
	    delete $state->{error};
	    write_job_state($jobcfg,  $state);
	}
    }
}

sub replication_snapshot_name {
    my ($jobid, $last_sync) = @_;

    my $prefix = "__replicate_${jobid}_";
    my $snapname = "${prefix}${last_sync}__";

    wantarray ? ($prefix, $snapname) : $snapname;
}

sub purge_old_states {

    my $local_node = PVE::INotify::nodename();

    my $cfg = PVE::ReplicationConfig->new();
    PVE::Cluster::cfs_update(1); # fail if we cannot query the vm list
    my $vms = PVE::Cluster::get_vmlist();

    my $used_tids = {};

    foreach my $jobid (sort keys %{$cfg->{ids}}) {
	my $jobcfg = $cfg->{ids}->{$jobid};
	my $plugin = PVE::ReplicationConfig->lookup($jobcfg->{type});
	my $tid = $plugin->get_unique_target_id($jobcfg);
	my $vmid = $jobcfg->{guest};
	$used_tids->{$vmid}->{$tid} = 1
	    if defined($vms->{ids}->{$vmid}); # && $vms->{ids}->{$vmid}->{node} eq $local_node;
    }

    my $purge_state = sub {
	my $stateobj = read_state();
	my $next_stateobj = {};

	foreach my $vmid (keys %$stateobj) {
	    foreach my $tid (keys %{$stateobj->{$vmid}}) {
		$next_stateobj->{$vmid}->{$tid} = $stateobj->{$vmid}->{$tid} if $used_tids->{$vmid}->{$tid};
	    }
	}
	PVE::Tools::file_set_contents($state_path, encode_json($next_stateobj));
    };

    PVE::Tools::lock_file($state_lock, 10, $purge_state);
    die $@ if $@;
}

sub job_status {
    my ($get_disabled) = @_;

    my $local_node = PVE::INotify::nodename();

    my $jobs = {};

    my $stateobj = read_state();

    my $cfg = PVE::ReplicationConfig->new();

    my $vms = PVE::Cluster::get_vmlist();

    my $func = sub {
	foreach my $jobid (sort keys %{$cfg->{ids}}) {
	    my $jobcfg = $cfg->{ids}->{$jobid};
	    my $vmid = $jobcfg->{guest};

	    die "internal error - not implemented" if $jobcfg->{type} ne 'local';

	    # skip non existing vms
	    next if !$vms->{ids}->{$vmid};

	    # only consider guest on local node
	    next if $vms->{ids}->{$vmid}->{node} ne $local_node;

	    my $target = $jobcfg->{target};
	    if (!$jobcfg->{remove_job}) {
		# check if vm was stolen (swapped source target)
		if ($target eq $local_node) {
		    my $source = $jobcfg->{source};
		    if (defined($source) && $source ne $target) {
			$jobcfg = PVE::ReplicationConfig::swap_source_target_nolock($jobid);
			$cfg->{ids}->{$jobid} = $jobcfg;
		    } else {
			# never sync to local node
			next;
		    }
		}

		next if !$get_disabled && $jobcfg->{disable};
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
		    my $members = PVE::Cluster::get_members();
		    if (!$fail_count || ($members->{$target} && $members->{$target}->{online})) {
			$next_sync = $state->{last_try} + 60*($fail_count < 3 ? 5*$fail_count : 30);
		    }
		} else {
		    my $schedule =  $jobcfg->{schedule} || '*/15';
		    my $calspec = PVE::CalendarEvent::parse_calendar_event($schedule);
		    $next_sync = PVE::CalendarEvent::compute_next_event($calspec, $state->{last_try}) // 0;
		}
	    }

	    $jobcfg->{next_sync} = $next_sync;

	    if (!defined($jobcfg->{source}) || $jobcfg->{source} ne $local_node) {
		$jobcfg->{source} = $cfg->{ids}->{$jobid}->{source} = $local_node;
		PVE::ReplicationConfig::write($cfg);
	    }

	    $jobs->{$jobid} = $jobcfg;
	}
    };

    PVE::ReplicationConfig::lock($func);

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
	my $res = $sa->{last_iteration} <=> $sb->{last_iteration};
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

sub schedule_job_now {
    my ($jobcfg) = @_;

    PVE::GuestHelpers::guest_migration_lock($jobcfg->{guest}, undef, sub {
	PVE::Tools::lock_file($state_lock, 10, sub {
	    my $stateobj = read_state();
	    my $vmid = $jobcfg->{guest};
	    my $plugin = PVE::ReplicationConfig->lookup($jobcfg->{type});
	    my $tid = $plugin->get_unique_target_id($jobcfg);
	    # no not modify anything if there is no state
	    return if !defined($stateobj->{$vmid}->{$tid});

	    my $state = read_job_state($jobcfg);
	    $state->{last_try} = 0;
	    write_job_state($jobcfg, $state);
	});
	die $@ if $@;
    });
}

1;
