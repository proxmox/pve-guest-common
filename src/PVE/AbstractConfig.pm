package PVE::AbstractConfig;

use strict;
use warnings;

use PVE::Tools qw(lock_file lock_file_full);
use PVE::INotify;
use PVE::Cluster;
use PVE::Storage;

use PVE::GuestHelpers qw(typesafe_ne);
use PVE::ReplicationConfig;
use PVE::Replication;

my $nodename = PVE::INotify::nodename();

# Printable string, currently either "VM" or "CT"
sub guest_type {
    my ($class) = @_;
    die "abstract method - implement me ";
}

sub __config_max_unused_disks {
    my ($class) = @_;

    die "implement me - abstract method\n";
}

# Path to the flock file for this VM/CT
sub config_file_lock {
    my ($class, $vmid) = @_;
    die "abstract method - implement me";
}

# Relative config file path for this VM/CT in CFS
sub cfs_config_path {
    my ($class, $vmid, $node) = @_;
    die "abstract method - implement me";
}

# Absolute config file path for this VM/CT
sub config_file {
    my ($class, $vmid, $node) = @_;

    my $cfspath = $class->cfs_config_path($vmid, $node);
    return "/etc/pve/$cfspath";
}

# Read and parse config file for this VM/CT
sub load_config {
    my ($class, $vmid, $node) = @_;

    $node = $nodename if !$node;
    my $cfspath = $class->cfs_config_path($vmid, $node);

    my $conf = PVE::Cluster::cfs_read_file($cfspath);
    die "Configuration file '$cfspath' does not exist\n"
	if !defined($conf);

    return $conf;
}

# Generate and write config file for this VM/CT
sub write_config {
    my ($class, $vmid, $conf) = @_;

    my $cfspath = $class->cfs_config_path($vmid);

    PVE::Cluster::cfs_write_file($cfspath, $conf);
}

# Pending changes related

sub parse_pending_delete {
    my ($class, $data) = @_;

    return {} if !$data;

    $data =~ s/[,;]/ /g;
    $data =~ s/^\s+//;

    my $pending_deletions = {};
    for my $entry (split(/\s+/, $data)) {
	my ($force, $key) = $entry =~ /^(!?)(.*)$/;
	$pending_deletions->{$key} = {
	    force => $force ? 1 : 0,
	};
    }

    return $pending_deletions;
}

sub print_pending_delete {
    my ($class, $delete_hash) = @_;

    my $render_key = sub {
	my $key = shift;
	$key = "!$key" if $delete_hash->{$key}->{force};
	return $key;
    };

    join (',', map { $render_key->($_) } sort keys %$delete_hash);
}

sub add_to_pending_delete {
    my ($class, $conf, $key, $force) = @_;

    $conf->{pending} //= {};
    my $pending = $conf->{pending};
    my $pending_delete_hash = $class->parse_pending_delete($pending->{delete});

    $pending_delete_hash->{$key} = { force => $force };

    $pending->{delete} = $class->print_pending_delete($pending_delete_hash);

    return $conf;
}

sub remove_from_pending_delete {
    my ($class, $conf, $key) = @_;

    my $pending = $conf->{pending};
    my $pending_delete_hash = $class->parse_pending_delete($pending->{delete});

    return $conf if ! exists $pending_delete_hash->{$key};

    delete $pending_delete_hash->{$key};

    if (%$pending_delete_hash) {
	$pending->{delete} = $class->print_pending_delete($pending_delete_hash);
    } else {
	delete $pending->{delete};
    }

    return $conf;
}

sub cleanup_pending {
    my ($class, $conf) = @_;

    my $pending = $conf->{pending};
    # remove pending changes when nothing changed
    my $changes;
    foreach my $opt (keys %{$conf->{pending}}) {
	next if $opt eq 'delete'; # just to be sure
	if (defined($conf->{$opt}) && ($pending->{$opt} eq $conf->{$opt})) {
	    $changes = 1;
	    delete $pending->{$opt};
	}
    }

    my $current_delete_hash = $class->parse_pending_delete($pending->{delete});
    my $pending_delete_hash = {};
    for my $opt (keys %$current_delete_hash) {
	if (defined($conf->{$opt})) {
	    $pending_delete_hash->{$opt} = $current_delete_hash->{$opt};
	} else {
	    $changes = 1;
	}
    }

    if (%$pending_delete_hash) {
	$pending->{delete} = $class->print_pending_delete($pending_delete_hash);
    } else {
	delete $pending->{delete};
    }

    return $changes;
}

sub get_partial_fast_plug_option {
    my ($class) = @_;

    die "abstract method - implement me ";
}

sub partial_fast_plug {
    my ($class, $conf, $opt) = @_;

    my $partial_fast_plug_option = $class->get_partial_fast_plug_option();
    return 0 if !$partial_fast_plug_option->{$opt};

    my $format = $partial_fast_plug_option->{$opt}->{fmt};
    my $fast_pluggable = $partial_fast_plug_option->{$opt}->{properties};

    my $configured = {};
    if (exists($conf->{$opt})) {
	$configured = PVE::JSONSchema::parse_property_string($format, $conf->{$opt});
    }
    my $pending = PVE::JSONSchema::parse_property_string($format, $conf->{pending}->{$opt});

    my $changes = 0;

    # merge configured and pending opts to iterate
    my @all_keys = keys %{{ %$pending, %$configured }};

    foreach my $subopt (@all_keys) {
	my $type = $format->{$subopt}->{type};
	if (typesafe_ne($configured->{$subopt}, $pending->{$subopt}, $type)) {
	    if ($fast_pluggable->{$subopt}) {
		$configured->{$subopt} = $pending->{$subopt};
		$changes = 1
	    }
	}
    }

    # if there're no keys in $configured (after merge) there shouldn't be anything to change
    if (keys %$configured) {
	$conf->{$opt} = PVE::JSONSchema::print_property_string($configured, $format);
    }

    return $changes;
}


sub load_snapshot_config {
    my ($class, $vmid, $snapname) = @_;

    my $conf = $class->load_config($vmid);

    my $snapshot = $conf->{snapshots}->{$snapname};
    die "snapshot '$snapname' does not exist\n" if !defined($snapshot);

    $snapshot->{digest} = $conf->{digest};

    return $snapshot;

}

sub load_current_config {
    my ($class, $vmid, $current) = @_;

    my $conf = $class->load_config($vmid);

    # take pending changes in
    if (!$current) {
	foreach my $opt (keys %{$conf->{pending}}) {
	    next if $opt eq 'delete';
	    my $value = $conf->{pending}->{$opt};
	    next if ref($value); # just to be sure
	    $conf->{$opt} = $value;
	}
	my $pending_delete_hash = $class->parse_pending_delete($conf->{pending}->{delete});
	foreach my $opt (keys %$pending_delete_hash) {
	    delete $conf->{$opt} if $conf->{$opt};
	}
    }

    delete $conf->{snapshots};
    delete $conf->{pending};

    return $conf;
}

sub create_and_lock_config {
    my ($class, $vmid, $allow_existing, $lock) = @_;

    $class->lock_config_full($vmid, 5, sub {
	PVE::Cluster::check_vmid_unused($vmid, $allow_existing);

	my $conf = eval { $class->load_config($vmid) } || {};
	$class->check_lock($conf);
	$conf->{lock} = $lock // 'create';
	$class->write_config($vmid, $conf);
    });
}

# destroys configuration, only applicable for configs owned by the callers node.
# dies if removal fails, e.g., when inquorate.
sub destroy_config {
    my ($class, $vmid) = @_;

    my $config_fn = $class->config_file($vmid, $nodename);
    unlink $config_fn or die "failed to remove config file: $!\n";
}

# moves configuration owned by calling node to the target node.
# dies if renaming fails.
# NOTE: in PVE a node owns the config (hard requirement), so only the owning
# node may move the config to another node, which then becomes the new owner.
sub move_config_to_node {
    my ($class, $vmid, $target_node) = @_;

    my $config_fn = $class->config_file($vmid);
    my $new_config_fn = $class->config_file($vmid, $target_node);

    rename($config_fn, $new_config_fn)
	or die "failed to move config file to node '$target_node': $!\n";
}

my $lock_file_full_wrapper = sub {
    my ($class, $vmid, $timeout, $shared, $realcode, @param) = @_;

    my $filename = $class->config_file_lock($vmid);

    # make sure configuration file is up-to-date
    my $code = sub {
	PVE::Cluster::cfs_update();
	$realcode->(@_);
    };

    my $res = lock_file_full($filename, $timeout, $shared, $code, @param);

    die $@ if $@;

    return $res;
};

# Lock config file using non-exclusive ("read") flock, run $code with @param, unlock config file.
# $timeout is the maximum time to acquire the flock
sub lock_config_shared {
    my ($class, $vmid, $timeout, $code, @param) = @_;

    return $lock_file_full_wrapper->($class, $vmid, $timeout, 1, $code, @param);
}

# Lock config file using flock, run $code with @param, unlock config file.
# $timeout is the maximum time to acquire the flock
sub lock_config_full {
    my ($class, $vmid, $timeout, $code, @param) = @_;

    return $lock_file_full_wrapper->($class, $vmid, $timeout, 0, $code, @param);
}


# Lock config file using flock, run $code with @param, unlock config file.
sub lock_config {
    my ($class, $vmid, $code, @param) = @_;

    return $class->lock_config_full($vmid, 10, $code, @param);
}

# Checks whether the config is locked with the lock parameter
sub check_lock {
    my ($class, $conf) = @_;

    die $class->guest_type()." is locked ($conf->{lock})\n" if $conf->{lock};
}

# Returns whether the config is locked with the lock parameter, also checks
# whether the lock value is correct if the optional $lock is set.
sub has_lock {
    my ($class, $conf, $lock) = @_;

    return $conf->{lock} && (!defined($lock) || $lock eq $conf->{lock});
}

# Sets the lock parameter for this VM/CT's config to $lock.
sub set_lock {
    my ($class, $vmid, $lock) = @_;

    my $conf;
    $class->lock_config($vmid, sub {
	$conf = $class->load_config($vmid);
	$class->check_lock($conf);
	$conf->{lock} = $lock;
	$class->write_config($vmid, $conf);
    });
    return $conf;
}

# Removes the lock parameter for this VM/CT's config, also checks whether
# the lock value is correct if the optional $lock is set.
sub remove_lock {
    my ($class, $vmid, $lock) = @_;

    $class->lock_config($vmid, sub {
	my $conf = $class->load_config($vmid);
	if (!$conf->{lock}) {
	    my $lockstring = defined($lock) ? "'$lock' " : "any";
	    die "no lock found trying to remove $lockstring lock\n";
	} elsif (defined($lock) && $conf->{lock} ne $lock) {
	    die "found lock '$conf->{lock}' trying to remove '$lock' lock\n";
	}
	delete $conf->{lock};
	$class->write_config($vmid, $conf);
    });
}

# Checks whether protection mode is enabled for this VM/CT.
sub check_protection {
    my ($class, $conf, $err_msg) = @_;

    if ($conf->{protection}) {
	die "$err_msg - protection mode enabled\n";
    }
}

# Returns a list of keys where used volumes can be located
sub valid_volume_keys {
    my ($class, $reverse) = @_;

    die "implement me - abstract method\n";
}

# Returns a hash with the information from $volume_string
# $key is used to determine the format of the string
sub parse_volume {
    my ($class, $key, $volume_string, $noerr) = @_;

    die "implement me - abstract method\n";
}

# Returns a string with the information from $volume
# $key is used to determine the format of the string
sub print_volume {
    my ($class, $key, $volume) = @_;

    die "implement me - abstract method\n";
}

# The key under which the volume ID is located in volume hashes
sub volid_key {
    my ($class) = @_;

    die "implement me - abstract method\n";
}

# Adds an unused volume to $config, if possible.
sub add_unused_volume {
    my ($class, $config, $volid) = @_;

    my $key;
    for (my $ind = $class->__config_max_unused_disks() - 1; $ind >= 0; $ind--) {
	my $test = "unused$ind";
	if (my $vid = $config->{$test}) {
	    return if $vid eq $volid; # do not add duplicates
	} else {
	    $key = $test;
	}
    }

    die "Too many unused volumes - please delete them first.\n" if !$key;

    $config->{$key} = $volid;

    return $key;
}

# Iterate over all unused volumes, calling $func for each key/value pair
# with additional parameters @param.
sub foreach_unused_volume {
    my ($class, $conf, $func, @param) = @_;

    foreach my $key (keys %{$conf}) {
	if ($key =~ m/^unused\d+$/) {
	    my $volume = $class->parse_volume($key, $conf->{$key});
	    $func->($key, $volume, @param);
	}
    }
}

# Iterate over all configured volumes, calling $func for each key/value pair
# with additional parameters @param.
# By default, unused volumes and specials like vmstate are excluded.
# Options: reverse         - reverses the order for the iteration
#	   include_unused  - also iterate over unused volumes
#	   extra_keys      - an array of extra keys to use for the iteration
sub foreach_volume_full {
    my ($class, $conf, $opts, $func, @param) = @_;

    die "'reverse' iteration only supported for default keys\n"
	if $opts->{reverse} && ($opts->{extra_keys} || $opts->{include_unused});

    my @keys = $class->valid_volume_keys($opts->{reverse});
    push @keys, @{$opts->{extra_keys}} if $opts->{extra_keys};

    foreach my $key (@keys) {
	my $volume_string = $conf->{$key};
	next if !defined($volume_string);

	my $volume = $class->parse_volume($key, $volume_string, 1);
	next if !defined($volume);

	$func->($key, $volume, @param);
    }

    $class->foreach_unused_volume($conf, $func, @param) if $opts->{include_unused};
}

sub foreach_volume {
    my ($class, $conf, $func, @param) = @_;

    return $class->foreach_volume_full($conf, undef, $func, @param);
}

# $volume_map is a hash of 'old_volid' => 'new_volid' pairs.
# This method replaces 'old_volid' by 'new_volid' throughout the config including snapshots, pending
# changes, unused volumes and vmstate volumes.
sub update_volume_ids {
    my ($class, $conf, $volume_map) = @_;

    my $volid_key = $class->volid_key();

    my $do_replace = sub {
	my ($key, $volume, $current_section) = @_;

	my $old_volid = $volume->{$volid_key};
	if (my $new_volid = $volume_map->{$old_volid}) {
	    $volume->{$volid_key} = $new_volid;
	    $current_section->{$key} = $class->print_volume($key, $volume);
	}
    };

    my $opts = {
	'include_unused' => 1,
	'extra_keys' => ['vmstate'],
    };

    $class->foreach_volume_full($conf, $opts, $do_replace, $conf);

    if (defined($conf->{snapshots})) {
	for my $snap (keys %{$conf->{snapshots}}) {
	    my $snap_conf = $conf->{snapshots}->{$snap};
	    $class->foreach_volume_full($snap_conf, $opts, $do_replace, $snap_conf);
	}
    }

    if (defined($conf->{pending})) {
	$class->foreach_volume_full($conf->{pending}, $opts, $do_replace, $conf->{pending});
    }
}

# Returns whether the template parameter is set in $conf.
sub is_template {
    my ($class, $conf) = @_;

    return 1 if defined $conf->{template} && $conf->{template} == 1;
}

# Checks whether $feature is available for the referenced volumes in $conf.
# Note: depending on the parameters, some volumes may be skipped!
sub has_feature {
    my ($class, $feature, $conf, $storecfg, $snapname, $running, $backup_only) = @_;
    die "implement me - abstract method\n";
}

# get all replicatable volume (hash $res->{$volid} = 1)
# $cleanup: for cleanup - simply ignores volumes without replicate feature
# $norerr: never raise exceptions - return undef instead
sub get_replicatable_volumes {
    my ($class, $storecfg, $vmid, $conf, $cleanup, $noerr) = @_;

    die "implement me - abstract method\n";
}

# Returns all the guests volumes which would be included in a vzdump job
# Return Format (array-ref with hash-refs as elements):
# [
#   {
#     key,		key in the config, e.g. mp0, scsi0,...
#     included,		boolean
#     reason,		string
#     volume_config	volume object as returned from foreach_volume()
#   },
# ]
sub get_backup_volumes {
    my ($class, $conf) = @_;

    die "implement me - abstract method\n";
}

# Internal snapshots

# NOTE: Snapshot create/delete involves several non-atomic
# actions, and can take a long time.
# So we try to avoid locking the file and use the 'lock' variable
# inside the config file instead.

# Save the vmstate (RAM).
sub __snapshot_save_vmstate {
    my ($class, $vmid, $conf, $snapname, $storecfg) = @_;
    die "implement me - abstract method\n";
}

# Check whether the VM/CT is running.
sub __snapshot_check_running {
    my ($class, $vmid) = @_;
    die "implement me - abstract method\n";
}

# Check whether we need to freeze the VM/CT
sub __snapshot_check_freeze_needed {
    my ($sself, $vmid, $config, $save_vmstate) = @_;
    die "implement me - abstract method\n";
}

# Freeze or unfreeze the VM/CT.
sub __snapshot_freeze {
    my ($class, $vmid, $unfreeze) = @_;

    die "abstract method - implement me\n";
}

# Code run before and after creating all the volume snapshots
# base: noop
sub __snapshot_create_vol_snapshots_hook {
    my ($class, $vmid, $snap, $running, $hook) = @_;

    return;
}

# Create the volume snapshots for the VM/CT.
sub __snapshot_create_vol_snapshot {
    my ($class, $vmid, $vs, $volume, $snapname) = @_;

    die "abstract method - implement me\n";
}

# Remove a drive from the snapshot config.
sub __snapshot_delete_remove_drive {
    my ($class, $snap, $drive) = @_;

    die "abstract method - implement me\n";
}

# Delete the vmstate file/drive
sub __snapshot_delete_vmstate_file {
    my ($class, $snap, $force) = @_;

    die "abstract method - implement me\n";
}

# Delete a volume snapshot
sub __snapshot_delete_vol_snapshot {
    my ($class, $vmid, $vs, $volume, $snapname) = @_;

    die "abstract method - implement me\n";
}

# called during rollback prepare, and between config rollback and starting guest
# can change config, e.g. for vmgenid
# $data is shared across calls and passed to vm_start
sub __snapshot_rollback_hook {
    my ($class, $vmid, $conf, $snap, $prepare, $data) = @_;

    return;
}

# Checks whether a volume snapshot is possible for this volume.
sub __snapshot_rollback_vol_possible {
    my ($class, $volume, $snapname) = @_;

    die "abstract method - implement me\n";
}

# Rolls back this volume.
sub __snapshot_rollback_vol_rollback {
    my ($class, $volume, $snapname) = @_;

    die "abstract method - implement me\n";
}

# Stops the VM/CT for a rollback.
sub __snapshot_rollback_vm_stop {
    my ($class, $vmid) = @_;

    die "abstract method - implement me\n";
}

# Start the VM/CT after a rollback with restored vmstate.
sub __snapshot_rollback_vm_start {
    my ($class, $vmid, $vmstate, $data);

    die "abstract method - implement me\n";
}

# Get list of volume IDs which are referenced in $conf, but not in $snap.
sub __snapshot_rollback_get_unused {
    my ($class, $conf, $snap) = @_;

    die "abstract method - implement me\n";
}

# Copy the current config $source to the snapshot config $dest
sub __snapshot_copy_config {
    my ($class, $source, $dest) = @_;

    foreach my $k (keys %$source) {
	next if $k eq 'snapshots';
	next if $k eq 'snapstate';
	next if $k eq 'snaptime';
	next if $k eq 'vmstate';
	next if $k eq 'lock';
	next if $k eq 'digest';
	next if $k eq 'description';
	next if $k =~ m/^unused\d+$/;

	$dest->{$k} = $source->{$k};
    }
};

# Apply the snapshot config $snap to the config $conf (rollback)
sub __snapshot_apply_config {
    my ($class, $conf, $snap) = @_;

    # copy snapshot list
    my $newconf = {
	snapshots => $conf->{snapshots},
    };

    # keep description and list of unused disks
    foreach my $k (keys %$conf) {
	next if !($k =~ m/^unused\d+$/ || $k eq 'description');

	$newconf->{$k} = $conf->{$k};
    }

    $class->__snapshot_copy_config($snap, $newconf);

    return $newconf;
}

# Prepares the configuration for snapshotting.
sub __snapshot_prepare {
    my ($class, $vmid, $snapname, $save_vmstate, $comment) = @_;

    my $snap;

    my $updatefn =  sub {

	my $conf = $class->load_config($vmid);

	die "you can't take a snapshot if it's a template\n"
	    if $class->is_template($conf);

	$class->check_lock($conf);

	$conf->{lock} = 'snapshot';

	my $snapshots = $conf->{snapshots};

	die "snapshot name '$snapname' already used\n"
	    if defined($snapshots->{$snapname});

	my $storecfg = PVE::Storage::config();
	die "snapshot feature is not available\n"
	    if !$class->has_feature('snapshot', $conf, $storecfg, undef, undef, $snapname eq 'vzdump');

	for my $snap (sort keys %$snapshots) {
	    my $parent_name = $snapshots->{$snap}->{parent} // '';
	    if ($snapname eq $parent_name) {
		warn "deleting parent '$parent_name' reference from '$snap' to avoid bogus snapshot cycle.\n";
		delete $snapshots->{$snap}->{parent};
	    }
	}

	$snap = $snapshots->{$snapname} = {};

	if ($save_vmstate && $class->__snapshot_check_running($vmid)) {
	    $class->__snapshot_save_vmstate($vmid, $conf, $snapname, $storecfg);
	}

	$class->__snapshot_copy_config($conf, $snap);

	$snap->{snapstate} = "prepare";
	$snap->{snaptime} = time();
	$snap->{description} = $comment if $comment;

	$class->write_config($vmid, $conf);
    };

    $class->lock_config($vmid, $updatefn);

    return $snap;
}

# Commits the configuration after snapshotting.
sub __snapshot_commit {
    my ($class, $vmid, $snapname) = @_;

    my $updatefn = sub {

	my $conf = $class->load_config($vmid);

	die "missing snapshot lock\n"
	    if !($conf->{lock} && $conf->{lock} eq 'snapshot');

	my $snap = $conf->{snapshots}->{$snapname};
	die "snapshot '$snapname' does not exist\n" if !defined($snap);

	die "wrong snapshot state\n"
	    if !($snap->{snapstate} && $snap->{snapstate} eq "prepare");

	delete $snap->{snapstate};
	delete $conf->{lock};

	$conf->{parent} = $snapname;

	$class->write_config($vmid, $conf);
    };

    $class->lock_config($vmid, $updatefn);
}

# Activates the storages affected by the snapshot operations.
sub __snapshot_activate_storages {
    my ($class, $conf, $include_vmstate) = @_;

    # FIXME PVE 8.x (or earlier with break/versioned-depens): uncomment and drop return
    # die "implement me";
    return;
}

# Creates a snapshot for the VM/CT.
sub snapshot_create {
    my ($class, $vmid, $snapname, $save_vmstate, $comment) = @_;

    my $snap = $class->__snapshot_prepare($vmid, $snapname, $save_vmstate, $comment);

    $save_vmstate = 0 if !$snap->{vmstate};

    my $conf = $class->load_config($vmid);

    my ($running, $freezefs) = $class->__snapshot_check_freeze_needed($vmid, $conf, $snap->{vmstate});

    my $drivehash = {};

    eval {
	$class->__snapshot_activate_storages($conf, 0);

	if ($freezefs) {
	    $class->__snapshot_freeze($vmid, 0);
	}

	$class->__snapshot_create_vol_snapshots_hook($vmid, $snap, $running, "before");

	$class->foreach_volume($snap, sub {
	    my ($vs, $volume) = @_;

	    $class->__snapshot_create_vol_snapshot($vmid, $vs, $volume, $snapname);
	    $drivehash->{$vs} = 1;
	});
    };
    my $err = $@;

    if ($running) {
	$class->__snapshot_create_vol_snapshots_hook($vmid, $snap, $running, "after");
	if ($freezefs) {
	    $class->__snapshot_freeze($vmid, 1);
	}
	$class->__snapshot_create_vol_snapshots_hook($vmid, $snap, $running, "after-unfreeze");
    }

    if ($err) {
	warn "snapshot create failed: starting cleanup\n";
	eval { $class->snapshot_delete($vmid, $snapname, 1, $drivehash); };
	warn "$@" if $@;
	die "$err\n";
    }

    $class->__snapshot_commit($vmid, $snapname);
}

# Check if the snapshot might still be needed by a replication job.
my $snapshot_delete_assert_not_needed_by_replication = sub {
    my ($class, $vmid, $conf, $snap, $snapname) = @_;

    my $repl_conf = PVE::ReplicationConfig->new();
    return if !$repl_conf->check_for_existing_jobs($vmid, 1);

    my $storecfg = PVE::Storage::config();

    # Current config's volumes are relevant for replication.
    my $volumes = $class->get_replicatable_volumes($storecfg, $vmid, $conf, 1);

    my $replication_jobs = $repl_conf->list_guests_local_replication_jobs($vmid);

    $class->foreach_volume($snap, sub {
	my ($vs, $volume) = @_;

	my $volid_key = $class->volid_key();
	my $volid = $volume->{$volid_key};

	return if !$volumes->{$volid};

	my $snapshots = PVE::Storage::volume_snapshot_info($storecfg, $volid);

	for my $job ($replication_jobs->@*) {
	    my $jobid = $job->{id};

	    my @jobs_snapshots = grep {
		PVE::Replication::is_replication_snapshot($_, $jobid)
	    } keys $snapshots->%*;

	    next if scalar(@jobs_snapshots) > 0;

	    die "snapshot '$snapname' needed by replication job '$jobid' - run replication first\n";
	}
    });
};

# Deletes a snapshot.
# Note: $drivehash is only set when called from snapshot_create.
sub snapshot_delete {
    my ($class, $vmid, $snapname, $force, $drivehash) = @_;

    my $unused = [];

    my $conf = $class->load_config($vmid);
    my $snap = $conf->{snapshots}->{$snapname};

    die "snapshot '$snapname' does not exist\n" if !defined($snap);

    $class->__snapshot_activate_storages($snap, 1) if !$drivehash;

    $snapshot_delete_assert_not_needed_by_replication->($class, $vmid, $conf, $snap, $snapname)
	if !$drivehash && !$force;

    $class->set_lock($vmid, 'snapshot-delete')
	if (!$drivehash); # doesn't already have a 'snapshot' lock

    my $expected_lock = $drivehash ? 'snapshot' : 'snapshot-delete';

    my $ensure_correct_lock = sub {
	my ($conf) = @_;

	die "encountered invalid lock, expected '$expected_lock'\n"
	    if !$class->has_lock($conf, $expected_lock);
    };

    my $unlink_parent = sub {
	my ($confref, $new_parent) = @_;

	if ($confref->{parent} && $confref->{parent} eq $snapname) {
	    if ($new_parent) {
		$confref->{parent} = $new_parent;
	    } else {
		delete $confref->{parent};
	    }
	}
    };

    my $remove_drive = sub {
	my ($drive) = @_;

	my $conf = $class->load_config($vmid);
	$ensure_correct_lock->($conf);

	$snap = $conf->{snapshots}->{$snapname};
	die "snapshot '$snapname' does not exist\n" if !defined($snap);

	$class->__snapshot_delete_remove_drive($snap, $drive);

	$class->write_config($vmid, $conf);
    };

    #prepare
    $class->lock_config($vmid, sub {
	my $conf = $class->load_config($vmid);
	$ensure_correct_lock->($conf);

	die "you can't delete a snapshot if vm is a template\n"
	    if $class->is_template($conf);

	$snap = $conf->{snapshots}->{$snapname};
	die "snapshot '$snapname' does not exist\n" if !defined($snap);

	$snap->{snapstate} = 'delete';

	$class->write_config($vmid, $conf);
    });

    # now remove vmstate file
    if ($snap->{vmstate}) {
	$class->__snapshot_delete_vmstate_file($snap, $force);

	# save changes (remove vmstate from snapshot)
	$class->lock_config($vmid, $remove_drive, 'vmstate') if !$force;
    };

    # now remove all volume snapshots
    $class->foreach_volume($snap, sub {
	my ($vs, $volume) = @_;

	return if $snapname eq 'vzdump' && $vs ne 'rootfs' && !$volume->{backup};
	if (!$drivehash || $drivehash->{$vs}) {
	    eval { $class->__snapshot_delete_vol_snapshot($vmid, $vs, $volume, $snapname, $unused); };
	    if (my $err = $@) {
		die $err if !$force;
		warn $err;
	    }
	}

	# save changes (remove drive from snapshot)
	$class->lock_config($vmid, $remove_drive, $vs) if !$force;
    });

    # now cleanup config
    $class->lock_config($vmid, sub {
	my $conf = $class->load_config($vmid);
	$ensure_correct_lock->($conf);

	$snap = $conf->{snapshots}->{$snapname};
	die "snapshot '$snapname' does not exist\n" if !defined($snap);

	# remove parent refs
	&$unlink_parent($conf, $snap->{parent});
	foreach my $sn (keys %{$conf->{snapshots}}) {
	    next if $sn eq $snapname;
	    &$unlink_parent($conf->{snapshots}->{$sn}, $snap->{parent});
	}


	delete $conf->{snapshots}->{$snapname};
	delete $conf->{lock};
	foreach my $volid (@$unused) {
	    $class->add_unused_volume($conf, $volid);
	}

	$class->write_config($vmid, $conf);
    });
}

# Remove replication snapshots to make a rollback possible.
my $rollback_remove_replication_snapshots = sub {
    my ($class, $vmid, $snap, $snapname) = @_;

    my $storecfg = PVE::Storage::config();

    my $repl_conf = PVE::ReplicationConfig->new();
    return if !$repl_conf->check_for_existing_jobs($vmid, 1);

    my $volumes = $class->get_replicatable_volumes($storecfg, $vmid, $snap, 1);

    # For these, all replication snapshots need to be removed for backwards compatibility.
    my $volids = [];

    # For these, we know more and can remove only the required replication snapshots.
    my $blocking_snapshots = {};

    # filter by what we actually iterate over below (excludes vmstate!)
    $class->foreach_volume($snap, sub {
	my ($vs, $volume) = @_;

	my $volid_key = $class->volid_key();
	my $volid = $volume->{$volid_key};

	return if !$volumes->{$volid};

	my $blockers = [];
	eval { $class->__snapshot_rollback_vol_possible($volume, $snapname, $blockers); };
	if (my $err = $@) {
	    # FIXME die instead, once $blockers is required by the storage plugin API
	    # and the guest plugins are required to be new enough to support it too.
	    # Currently, it's not possible to distinguish between blockers being empty
	    # because the plugin is old versus because there is a different error.
	    if (scalar($blockers->@*) == 0) {
		push @{$volids}, $volid;
		return;
	    }

	    for my $blocker ($blockers->@*) {
		die $err if !PVE::Replication::is_replication_snapshot($blocker);
	    }

	    $blocking_snapshots->{$volid} = $blockers;
	}
    });

    my $removed_repl_snapshot;
    for my $volid (sort keys $blocking_snapshots->%*) {
	my $blockers = $blocking_snapshots->{$volid};

	for my $blocker ($blockers->@*) {
	    warn "WARN: removing replication snapshot '$volid\@$blocker'\n";
	    $removed_repl_snapshot = 1;
	    eval { PVE::Storage::volume_snapshot_delete($storecfg, $volid, $blocker); };
	    die $@ if $@;
	}
    }
    warn "WARN: you shouldn't remove '$snapname' before running the next replication!\n"
	if $removed_repl_snapshot;

    # Need to keep using a hammer for backwards compatibility...
    # remove all local replication snapshots (jobid => undef)
    my $logfunc = sub { my $line = shift; chomp $line; print "$line\n"; };
    PVE::Replication::prepare($storecfg, $volids, undef, 1, undef, $logfunc);
};

# Rolls back to a given snapshot.
sub snapshot_rollback {
    my ($class, $vmid, $snapname) = @_;

    my $prepare = 1;

    my $data = {};

    my $get_snapshot_config = sub {
	my ($conf) = @_;

	die "you can't rollback if vm is a template\n" if $class->is_template($conf);

	my $res = $conf->{snapshots}->{$snapname};

	die "snapshot '$snapname' does not exist\n" if !defined($res);

	return $res;
    };

    my $snap;

    my $updatefn = sub {
	my $conf = $class->load_config($vmid);
	$snap = $get_snapshot_config->($conf);

	if ($prepare) {
	    $class->__snapshot_activate_storages($snap, 1);

	    $rollback_remove_replication_snapshots->($class, $vmid, $snap, $snapname);

	    $class->foreach_volume($snap, sub {
	       my ($vs, $volume) = @_;

	       $class->__snapshot_rollback_vol_possible($volume, $snapname);
	    });
        }

	die "unable to rollback to incomplete snapshot (snapstate = $snap->{snapstate})\n"
	    if $snap->{snapstate};

	if ($prepare) {
	    $class->check_lock($conf);
	    $class->__snapshot_rollback_vm_stop($vmid);
	}

	die "unable to rollback vm $vmid: vm is running\n"
	    if $class->__snapshot_check_running($vmid);

	if ($prepare) {
	    $conf->{lock} = 'rollback';
	} else {
	    die "got wrong lock\n" if !($conf->{lock} && $conf->{lock} eq 'rollback');
	    delete $conf->{lock};

	    my $unused = $class->__snapshot_rollback_get_unused($conf, $snap);

	    foreach my $volid (@$unused) {
		$class->add_unused_volume($conf, $volid);
	    }

	    # copy snapshot config to current config
	    $conf = $class->__snapshot_apply_config($conf, $snap);
	    $conf->{parent} = $snapname;
	}

	$class->__snapshot_rollback_hook($vmid, $conf, $snap, $prepare, $data);

	$class->write_config($vmid, $conf);

	if (!$prepare && $snap->{vmstate}) {
	    $class->__snapshot_rollback_vm_start($vmid, $snap->{vmstate}, $data);
	}
    };

    $class->lock_config($vmid, $updatefn);

    $class->foreach_volume($snap, sub {
	my ($vs, $volume) = @_;

	$class->__snapshot_rollback_vol_rollback($volume, $snapname);
    });

    $prepare = 0;
    $class->lock_config($vmid, $updatefn);
}

# bash completion helper

sub snapshot_list {
    my ($class, $vmid) = @_;

    my $snapshot = eval {
	my $conf = $class->load_config($vmid);
	my $snapshots = $conf->{snapshots} || [];
	[ sort keys %$snapshots ]
    } || [];

    return $snapshot;
}

1;
