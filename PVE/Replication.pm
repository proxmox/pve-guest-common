package PVE::Replication;

use warnings;
use strict;
use Data::Dumper;
use JSON;
use Time::HiRes qw(gettimeofday tv_interval);
use POSIX qw(strftime);

use PVE::INotify;
use PVE::ProcFSTools;
use PVE::Tools;
use PVE::Cluster;
use PVE::Storage;
use PVE::GuestHelpers;
use PVE::ReplicationConfig;
use PVE::ReplicationState;


# regression tests should overwrite this
sub get_log_time {

    return strftime("%F %H:%M:%S", localtime);
}

# Find common base replication snapshot, available on local and remote side.
# Note: this also removes stale replication snapshots
sub find_common_replication_snapshot {
    my ($ssh_info, $jobid, $vmid, $storecfg, $volumes, $storeid_list, $last_sync, $parent_snapname, $logfunc) = @_;

    my $last_sync_snapname =
	PVE::ReplicationState::replication_snapshot_name($jobid, $last_sync);

    # test if we have a replication_ snapshot from last sync
    # and remove all other/stale replication snapshots

    my $last_snapshots = prepare(
	$storecfg, $volumes, $jobid, $last_sync, $parent_snapname, $logfunc);

    # prepare remote side
    my $remote_snapshots = remote_prepare_local_job(
	$ssh_info, $jobid, $vmid, $volumes, $storeid_list, $last_sync, $parent_snapname, 0, $logfunc);

    my $base_snapshots = {};

    foreach my $volid (@$volumes) {
	my $base_snapname;

	if (defined($last_snapshots->{$volid}) && defined($remote_snapshots->{$volid})) {
	    if ($last_snapshots->{$volid}->{$last_sync_snapname} &&
		$remote_snapshots->{$volid}->{$last_sync_snapname}) {
		$base_snapshots->{$volid} = $last_sync_snapname;
	    } elsif (defined($parent_snapname) &&
		     ($last_snapshots->{$volid}->{$parent_snapname} &&
		      $remote_snapshots->{$volid}->{$parent_snapname})) {
		$base_snapshots->{$volid} = $parent_snapname;
	    } elsif ($last_sync == 0) {
		my @desc_sorted_snap =
		    map { $_->[1] } sort { $b->[0] <=> $a->[0] }
		    map { [ ($_ =~ /__replicate_\Q$jobid\E_(\d+)_/)[0] || 0, $_ ] }
		    keys %{$remote_snapshots->{$volid}};

		foreach my $remote_snap (@desc_sorted_snap) {
		    if (defined($last_snapshots->{$volid}->{$remote_snap})) {
			$base_snapshots->{$volid} = $remote_snap;
			last;
		    }
		}
		die "No common base to restore the job state\n".
		    "please delete jobid: $jobid and create the job again\n"
		    if !defined($base_snapshots->{$volid});
	    }
	}
    }

    return ($base_snapshots, $last_snapshots, $last_sync_snapname);
}

sub remote_prepare_local_job {
    my ($ssh_info, $jobid, $vmid, $volumes, $storeid_list, $last_sync, $parent_snapname, $force, $logfunc) = @_;

    my $ssh_cmd = PVE::Cluster::ssh_info_to_command($ssh_info);
    my $cmd = [@$ssh_cmd, '--', 'pvesr', 'prepare-local-job', $jobid];
    push @$cmd, '--scan', join(',', @$storeid_list) if scalar(@$storeid_list);
    push @$cmd, @$volumes if scalar(@$volumes);

    push @$cmd, '--last_sync', $last_sync;
    push @$cmd, '--parent_snapname', $parent_snapname
	if $parent_snapname;
    push @$cmd, '--force' if $force;

    my $remote_snapshots;

    my $parser = sub {
	my $line = shift;
	$remote_snapshots = JSON::decode_json($line);
    };

    my $logger = sub {
	my $line = shift;
	chomp $line;
	$logfunc->("(remote_prepare_local_job) $line");
    };

    PVE::Tools::run_command($cmd, outfunc => $parser, errfunc => $logger);

    die "prepare remote node failed - no result\n"
	if !defined($remote_snapshots);

    return $remote_snapshots;
}

sub remote_finalize_local_job {
    my ($ssh_info, $jobid, $vmid, $volumes, $last_sync, $logfunc) = @_;

    my $ssh_cmd = PVE::Cluster::ssh_info_to_command($ssh_info);
    my $cmd = [@$ssh_cmd, '--', 'pvesr', 'finalize-local-job', $jobid,
	       @$volumes, '--last_sync', $last_sync];

    my $logger = sub {
	my $line = shift;
	chomp $line;
	$logfunc->("(remote_finalize_local_job) $line");
    };

    PVE::Tools::run_command($cmd, outfunc => $logger, errfunc => $logger);
}

# finds local replication snapshots from $last_sync
# and removes all replication snapshots with other time stamps
sub prepare {
    my ($storecfg, $volids, $jobid, $last_sync, $parent_snapname, $logfunc) = @_;

    $last_sync //= 0;

    my ($prefix, $snapname);

    if (defined($jobid)) {
	($prefix, $snapname) = PVE::ReplicationState::replication_snapshot_name($jobid, $last_sync);
    } else {
	$prefix = '__replicate_';
    }

    my $last_snapshots = {};
    my $cleaned_replicated_volumes = {};
    foreach my $volid (@$volids) {
	my $list = PVE::Storage::volume_snapshot_list($storecfg, $volid);
	foreach my $snap (@$list) {
	    if ((defined($snapname) && ($snap eq $snapname)) ||
		(defined($parent_snapname) && ($snap eq $parent_snapname))) {
		$last_snapshots->{$volid}->{$snap} = 1;
	    } elsif ($snap =~ m/^\Q$prefix\E/) {
		if ($last_sync != 0) {
		    $logfunc->("delete stale replication snapshot '$snap' on $volid");
		    eval {
			PVE::Storage::volume_snapshot_delete($storecfg, $volid, $snap);
			$cleaned_replicated_volumes->{$volid} = 1;
		    };

		    # If deleting the snapshot fails, we can not be sure if it was due to an error or a timeout.
		    # The likelihood that the delete has worked out is high at a timeout.
		    # If it really fails, it will try to remove on the next run.
		    if (my $err = $@) {
			# warn is for syslog/journal.
			warn $err;

			# logfunc will written in replication log.
			$logfunc->("delete stale replication snapshot error: $err");
		    }		
		# Last_sync=0 and a replication snapshot only occur, if the VM was stolen
		} else {
		    $last_snapshots->{$volid}->{$snap} = 1;
		}
	    }
	}
    }

    return wantarray ? ($last_snapshots, $cleaned_replicated_volumes) : $last_snapshots;
}

sub replicate_volume {
    my ($ssh_info, $storecfg, $volid, $base_snapshot, $sync_snapname, $rate, $insecure, $logfunc) = @_;

    my ($storeid, $volname) = PVE::Storage::parse_volume_id($volid);

    my $ratelimit_bps = int(1000000*$rate) if $rate;
    PVE::Storage::storage_migrate($storecfg, $volid, $ssh_info, $storeid, $volname,
				  $base_snapshot, $sync_snapname, $ratelimit_bps, $insecure, 1, $logfunc);
}


sub replicate {
    my ($guest_class, $jobcfg, $state, $start_time, $logfunc) = @_;

    my $local_node = PVE::INotify::nodename();

    die "not implemented - internal error" if $jobcfg->{type} ne 'local';

    my $dc_conf = PVE::Cluster::cfs_read_file('datacenter.cfg');

    my $migration_network;
    my $migration_type = 'secure';
    if (my $mc = $dc_conf->{migration}) {
	$migration_network = $mc->{network};
	$migration_type = $mc->{type} if defined($mc->{type});
    }

    my $jobid = $jobcfg->{id};
    my $storecfg = PVE::Storage::config();
    my $last_sync = $state->{last_sync};

    die "start time before last sync ($start_time <= $last_sync) - abort sync\n"
	if $start_time <= $last_sync;

    my $vmid = $jobcfg->{guest};

    my $conf = $guest_class->load_config($vmid);
    my ($running, $freezefs) = $guest_class->__snapshot_check_freeze_needed($vmid, $conf, 0);
    my $volumes = $guest_class->get_replicatable_volumes($storecfg, $vmid, $conf, defined($jobcfg->{remove_job}));

    my $sorted_volids = [ sort keys %$volumes ];

    $running //= 0;  # to avoid undef warnings from logfunc

    my $guest_name = $guest_class->guest_type() . ' ' . $vmid;

    $logfunc->("guest => $guest_name, running => $running");
    $logfunc->("volumes => " . join(',', @$sorted_volids));

    if (my $remove_job = $jobcfg->{remove_job}) {

	$logfunc->("start job removal - mode '${remove_job}'");

	if ($remove_job eq 'full' && $jobcfg->{target} ne $local_node) {
	    # remove all remote volumes
	    my @store_list = map { (PVE::Storage::parse_volume_id($_))[0] } @$sorted_volids;

	    my %hash = map { $_ => 1 } @store_list;

	    my $ssh_info = PVE::Cluster::get_ssh_info($jobcfg->{target});
	    remote_prepare_local_job($ssh_info, $jobid, $vmid, [], [ keys %hash ], 1, undef, 1, $logfunc);

	}
	# remove all local replication snapshots (lastsync => 0)
	prepare($storecfg, $sorted_volids, $jobid, 1, undef, $logfunc);

	PVE::ReplicationConfig::delete_job($jobid); # update config
	$logfunc->("job removed");

	return undef;
    }

    my $ssh_info = PVE::Cluster::get_ssh_info($jobcfg->{target}, $migration_network);

    my $parent_snapname = $conf->{parent};

    my ($base_snapshots, $last_snapshots, $last_sync_snapname) = find_common_replication_snapshot(
	$ssh_info, $jobid, $vmid, $storecfg, $sorted_volids, $state->{storeid_list}, $last_sync, $parent_snapname, $logfunc);

    my $storeid_hash = {};
    foreach my $volid (@$sorted_volids) {
	my ($storeid) = PVE::Storage::parse_volume_id($volid);
	$storeid_hash->{$storeid} = 1;
    }
    $state->{storeid_list} = [ sort keys %$storeid_hash ];

    # freeze filesystem for data consistency
    if ($freezefs) {
	$logfunc->("freeze guest filesystem");
	$guest_class->__snapshot_freeze($vmid, 0);
    }

    # make snapshot of all volumes
    my $sync_snapname =
	PVE::ReplicationState::replication_snapshot_name($jobid, $start_time);

    my $replicate_snapshots = {};
    eval {
	foreach my $volid (@$sorted_volids) {
	    $logfunc->("create snapshot '${sync_snapname}' on $volid");
	    PVE::Storage::volume_snapshot($storecfg, $volid, $sync_snapname);
	    $replicate_snapshots->{$volid} = 1;
	}
    };
    my $err = $@;

    # thaw immediately
    if ($freezefs) {
	$logfunc->("thaw guest filesystem");
	$guest_class->__snapshot_freeze($vmid, 1);
    }

    my $cleanup_local_snapshots = sub {
	my ($volid_hash, $snapname) = @_;
	foreach my $volid (sort keys %$volid_hash) {
	    $logfunc->("delete previous replication snapshot '$snapname' on $volid");
	    eval { PVE::Storage::volume_snapshot_delete($storecfg, $volid, $snapname); };
	    warn $@ if $@;
	}
    };

    if ($err) {
	$cleanup_local_snapshots->($replicate_snapshots, $sync_snapname); # try to cleanup
	die $err;
    }

    eval {

	my $rate = $jobcfg->{rate};
	my $insecure = $migration_type eq 'insecure';

	foreach my $volid (@$sorted_volids) {
	    my $base_snapname;

	    if (defined($base_snapname = $base_snapshots->{$volid})) {
		$logfunc->("incremental sync '$volid' ($base_snapname => $sync_snapname)");
	    } else {
		$logfunc->("full sync '$volid' ($sync_snapname)");
	    }

	    replicate_volume($ssh_info, $storecfg, $volid, $base_snapname, $sync_snapname, $rate, $insecure, $logfunc);
	}
    };

    if ($err = $@) {
	$cleanup_local_snapshots->($replicate_snapshots, $sync_snapname); # try to cleanup
	# we do not cleanup the remote side here - this is done in
	# next run of prepare_local_job
	die $err;
    }

    # remove old snapshots because they are no longer needed
    $cleanup_local_snapshots->($last_snapshots, $last_sync_snapname);

    eval {
	remote_finalize_local_job($ssh_info, $jobid, $vmid, $sorted_volids, $start_time, $logfunc);
    };

    # old snapshots will removed by next run from prepare_local_job.
    if ($err = $@) {
	# warn is for syslog/journal.
	warn $err;

	# logfunc will written in replication log.
	$logfunc->("delete stale replication snapshot error: $err");
    }

    return $volumes;
}

my $run_replication_nolock = sub {
    my ($guest_class, $jobcfg, $iteration, $start_time, $logfunc, $verbose) = @_;

    my $jobid = $jobcfg->{id};

    my $volumes;

    # we normaly write errors into the state file,
    # but we also catch unexpected errors and log them to syslog
    # (for examply when there are problems writing the state file)

    my $state = PVE::ReplicationState::read_job_state($jobcfg);

    PVE::ReplicationState::record_job_start($jobcfg, $state, $start_time, $iteration);

    my $t0 = [gettimeofday];

    mkdir $PVE::ReplicationState::replicate_logdir;
    my $logfile = PVE::ReplicationState::job_logfile_name($jobid);
    open(my $logfd, '>', $logfile) ||
	die "unable to open replication log '$logfile' - $!\n";

    my $logfunc_wrapper = sub {
	my ($msg) = @_;

	my $ctime = get_log_time();
	print $logfd "$ctime $jobid: $msg\n";
	if ($logfunc) {
	    if ($verbose) {
		$logfunc->("$ctime $jobid: $msg");
	    } else {
		$logfunc->($msg);
	    }
	}
    };

    $logfunc_wrapper->("start replication job");

    eval {
	$volumes = replicate($guest_class, $jobcfg, $state, $start_time, $logfunc_wrapper);
    };
    my $err = $@;

    if ($err) {
	my $msg = "end replication job with error: $err";
	chomp $msg;
	$logfunc_wrapper->($msg);
    } else {
	$logfunc_wrapper->("end replication job");
    }

    PVE::ReplicationState::record_job_end($jobcfg, $state, $start_time, tv_interval($t0), $err);

    close($logfd);

    die $err if $err;

    return $volumes;
};

sub run_replication {
    my ($guest_class, $jobcfg, $iteration, $start_time, $logfunc, $verbose) = @_;

    my $volumes;

    my $timeout = 2; # do not wait too long - we repeat periodically anyways
    $volumes = PVE::GuestHelpers::guest_migration_lock(
	$jobcfg->{guest}, $timeout, $run_replication_nolock,
	$guest_class, $jobcfg, $iteration, $start_time, $logfunc, $verbose);

    return $volumes;
}

1;
