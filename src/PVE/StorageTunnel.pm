package PVE::StorageTunnel;

use strict;
use warnings;

use IO::Socket::UNIX;
use POSIX qw(WNOHANG);
use Socket qw(SOCK_STREAM);

use PVE::Storage;
use PVE::Tools;
use PVE::Tunnel;

sub storage_migrate {
    my ($tunnel, $storecfg, $volid, $local_vmid, $remote_vmid, $opts, $log) = @_;

    my $targetsid = $opts->{targetsid};
    my $bwlimit = $opts->{bwlimit};

    # JSONSchema and get_bandwidth_limit use kbps - storage_migrate bps
    $bwlimit = $bwlimit * 1024 if defined($bwlimit);

    # adapt volume name for import call
    my ($sid, undef) = PVE::Storage::parse_volume_id($volid);
    my (undef, $name, $owner, undef, undef, undef, $format) = PVE::Storage::parse_volname($storecfg, $volid);
    my $scfg = PVE::Storage::storage_config($storecfg, $sid);
    PVE::Storage::activate_volumes($storecfg, [$volid]);

    die "failed to determine owner of volume '$volid'\n" if !defined($owner);
    $log->('warn', "volume '$volid' owner by VM/CT '$owner', not '$local_vmid'\n")
	if $owner != $local_vmid;

    if ($owner != $remote_vmid) {
	$name =~ s/-$owner-/-$remote_vmid-/g;
	$name =~ s/^$owner\///; # re-added on target if dir-based storage
    }

    my $with_snapshots = $opts->{snapshots} ? 1 : 0;
    my $snapshot;
    my $migration_snapshot = PVE::Storage::storage_migrate_snapshot($storecfg, $sid, $with_snapshots);
    if ($migration_snapshot) {
	$snapshot = '__migration__';
	$with_snapshots = 1;
    }

    my @export_formats = PVE::Storage::volume_export_formats($storecfg, $volid, $snapshot, undef, $with_snapshots);
    die "no export formats for '$volid' - check storage plugin support!\n"
	if !@export_formats;

    my $disk_import_opts = {
	format => $format,
	storage => $targetsid,
	snapshot => $snapshot,
	migration_snapshot => $migration_snapshot,
	with_snapshots => $with_snapshots,
	allow_rename => !$opts->{is_vmstate},
	export_formats => join(",", @export_formats),
	volname => $name,
    };
    my $res = PVE::Tunnel::write_tunnel($tunnel, 600, 'disk-import', $disk_import_opts);
    my $local = "/run/pve/$local_vmid.storage";
    if (!$tunnel->{forwarded}->{$local}) {
	PVE::Tunnel::forward_unix_socket($tunnel, $local, $res->{socket});
    }
    my $socket = IO::Socket::UNIX->new(Peer => $local, Type => SOCK_STREAM())
	or die "failed to connect to websocket tunnel at $local\n";
    # we won't be reading from the socket
    shutdown($socket, 0);

    my $disk_export_opts = {
	snapshot => $snapshot,
	migration_snapshot => $migration_snapshot,
	with_snapshots => $with_snapshots,
	ratelimit_bps => $bwlimit,
	cmd => {
	    output => '>&'.fileno($socket),
	},
    };

    eval {
	PVE::Storage::volume_export_start(
	    $storecfg,
	    $volid,
	    $res->{format},
	    sub { $log->('info', shift) },
	    $disk_export_opts,
	);
    };
    my $send_error = $@;
    warn "$send_error\n" if $send_error;

    # don't close the connection entirely otherwise the
    # receiving end might not get all buffered data (and
    # fails with 'connection reset by peer')
    shutdown($socket, 1);

    # wait for the remote process to finish
    my $new_volid;
    while ($res = PVE::Tunnel::write_tunnel($tunnel, 10, 'query-disk-import')) {
	if ($res->{status} eq 'pending') {
	    if (my $msg = $res->{msg}) {
		$log->('info', "disk-import: $msg\n");
	    } else {
		$log->('info', "waiting for disk import to finish..\n");
	    }
	    sleep(1)
	} elsif ($res->{status} eq 'complete') {
	    $new_volid = $res->{volid};
	    last;
	} else {
	    $log->('err', "unknown query-disk-import result: $res->{status}\n");
	    last;
	}
    }

    # now close the socket
    close($socket);
    if ($migration_snapshot) {
	eval { PVE::Storage::volume_snapshot_delete($storecfg, $volid, $snapshot, 0) };
	warn "could not remove source snapshot: $@\n" if $@;
    }
    die $send_error if $send_error;
    die "disk import failed - see log above\n" if !$new_volid;

    return $new_volid;
}

our $cmd_schema = {
    bwlimit => {
	storages => {
	    type => 'string',
	    format => 'pve-storage-id-list',
	    description => "Storage for which bwlimit is queried",
	},
	bwlimit => {
	    description => "Override I/O bandwidth limit (in KiB/s).",
	    optional => 1,
	    type => 'integer',
	    minimum => '0',
	},
	operation => {
	    description => 'Operation for which bwlimit is queried ("restore", "migration", "clone", "move")',
	    type => 'string',
	    default => 'migration',
	    optional => 1,
	},
    },
    'disk-import' => {
	volname => {
	    type => 'string',
	    description => 'volume name to use as preferred target volume name',
	},
	format => PVE::JSONSchema::get_standard_option('pve-qm-image-format'),
	export_formats => {
	    type => 'string',
	    description => 'list of supported export formats',
	},
	storage => {
	    type => 'string',
	    format => 'pve-storage-id',
	},
	snapshot => {
	    description => "The current-state snapshot if the stream contains snapshots",
	    type => 'string',
	    pattern => qr/[a-z0-9_\-]{1,40}/i,
	    optional => 1,
	},
	migration_snapshot => {
	    type => 'boolean',
	    optional => 1,
	    description => '`snapshot` was created for migration and will be removed after import',
	},
	with_snapshots => {
	    description => 'Whether the stream includes intermediate snapshots',
	    type => 'boolean',
	    optional => 1,
	    default => 0,
	},
	allow_rename => {
	    description => "Choose a new volume ID if the requested " .
		"volume ID already exists, instead of throwing an error.",
	    type => 'boolean',
	    optional => 1,
	    default => 0,
	},
    },
    'query-disk-import' => {},
};

sub handle_disk_import {
    my ($state, $params) = @_;

    die "disk import already running as PID '$state->{disk_import}->{pid}'\n"
	if $state->{disk_import}->{pid};

    my $storage = delete $params->{storage};
    my $format = delete $params->{format};
    my $volname = delete $params->{volname};

    my $import = PVE::Storage::volume_import_start($state->{storecfg}, $storage, $volname, $format, $state->{vmid}, $params);

    my $socket = $import->{socket};
    $format = delete $import->{format};

    $state->{sockets}->{$socket} = 1;
    $state->{disk_import} = $import;

    chown $state->{socket_uid}, -1, $socket;

    return {
	socket => $socket,
	format => $format,
    };
}

sub handle_query_disk_import {
    my ($state, $params) = @_;

    die "no disk import running\n"
	if !$state->{disk_import}->{pid};

    my $pattern = PVE::Storage::volume_imported_message(undef, 1);

    my $read_output = sub {
	my ($timeout) = @_;

	my $line;

	eval {
	    my $fh = $state->{disk_import}->{fh};
	    PVE::Tools::run_with_timeout($timeout, sub { $line = <$fh>; });
	    print "disk-import: $line\n" if $line;
        };

	return $line;
    };

    my $result = $read_output->(5);

    # attempted read empty or timeout, and process has exited already
    if (!$result && waitpid($state->{disk_import}->{pid}, WNOHANG)) {
	my $msg = '';

	# read any missed output
	while (my $line = $read_output->(1)) {
	    if ($line =~ $pattern) {
		$result = $line;
	    } else {
		$msg .= "$line\n";
	    }
	}

	my $unix = $state->{disk_import}->{socket};
	unlink $unix;
	delete $state->{sockets}->{$unix};
	delete $state->{disk_import};

	if (!$result) {
	    $msg = "import process failed\n" if !$msg;
	    return {
		status => "error",
		msg => $msg,
	    };
	}
    }

    if ($result && $result =~ $pattern) {
	my $volid = $1;
	waitpid($state->{disk_import}->{pid}, 0);

	my $unix = $state->{disk_import}->{socket};
	unlink $unix;
	delete $state->{sockets}->{$unix};
	delete $state->{disk_import};
	$state->{cleanup}->{volumes}->{$volid} = 1;
	return {
	    status => "complete",
	    volid => $volid,
	};
    } else {
	return {
	    status => "pending",
	    msg => $result,
	};
    }
}

sub handle_bwlimit {
    my ($params) = @_;

    my $op = $params->{operation} // "migration";
    my $storages = $params->{storages};
    my $override = $params->{bwlimit};

    return { bwlimit => PVE::Storage::get_bandwidth_limit($op, $storages, $override) };
}
