package PVE::VZDump::Common;

use strict;
use warnings;
use Digest::SHA;

use PVE::Tools;
use PVE::SafeSyslog qw(syslog);
use PVE::Storage;
use PVE::Cluster qw(cfs_register_file);
use PVE::JSONSchema qw(get_standard_option);

# NOTE: this is the legacy config, nowadays jobs.cfg is used (handled in pve-manager)
cfs_register_file(
    'vzdump.cron',
    \&parse_vzdump_cron_config,
    \&write_vzdump_cron_config,
);

my $dowhash_to_dow = sub {
    my ($d, $num) = @_;

    my @da = ();
    push @da, $num ? 1 : 'mon' if $d->{mon};
    push @da, $num ? 2 : 'tue' if $d->{tue};
    push @da, $num ? 3 : 'wed' if $d->{wed};
    push @da, $num ? 4 : 'thu' if $d->{thu};
    push @da, $num ? 5 : 'fri' if $d->{fri};
    push @da, $num ? 6 : 'sat' if $d->{sat};
    push @da, $num ? 7 : 'sun' if $d->{sun};

    return join ',', @da;
};

our $PROPERTY_STRINGS = {
    'performance' => 'backup-performance',
    'prune-backups' => 'prune-backups',
};

my sub parse_property_strings {
    my ($opts) = @_;

    for my $opt (keys $PROPERTY_STRINGS->%*) {
	next if !defined($opts->{$opt});

	my $format = $PROPERTY_STRINGS->{$opt};
	$opts->{$opt} = PVE::JSONSchema::parse_property_string($format, $opts->{$opt});
    }
}

# parse crontab style day of week
sub parse_dow {
    my ($dowstr, $noerr) = @_;

    my $dowmap = {mon => 1, tue => 2, wed => 3, thu => 4,
		  fri => 5, sat => 6, sun => 7};
    my $rdowmap = { '1' => 'mon', '2' => 'tue', '3' => 'wed', '4' => 'thu',
		    '5' => 'fri', '6' => 'sat', '7' => 'sun', '0' => 'sun'};

    my $res = {};

    $dowstr = '1,2,3,4,5,6,7' if $dowstr eq '*';

    foreach my $day (PVE::Tools::split_list($dowstr)) {
	if ($day =~ m/^(mon|tue|wed|thu|fri|sat|sun)-(mon|tue|wed|thu|fri|sat|sun)$/i) {
	    for (my $i = $dowmap->{lc($1)}; $i <= $dowmap->{lc($2)}; $i++) {
		my $r = $rdowmap->{$i};
		$res->{$r} = 1;
	    }
	} elsif ($day =~ m/^(mon|tue|wed|thu|fri|sat|sun|[0-7])$/i) {
	    $day = $rdowmap->{$day} if $day =~ m/\d/;
	    $res->{lc($day)} = 1;
	} else {
	    return undef if $noerr;
	    die "unable to parse day of week '$dowstr'\n";
	}
    }

    return $res;
};

PVE::JSONSchema::register_format('backup-performance', {
    'max-workers' => {
	description => "Applies to VMs. Allow up to this many IO workers at the same time.",
	type => 'integer',
	minimum => 1,
	maximum => 256,
	default => 16,
	optional => 1,
    },
});

my $confdesc = {
    vmid => {
	type => 'string', format => 'pve-vmid-list',
	description => "The ID of the guest system you want to backup.",
	completion => \&PVE::Cluster::complete_local_vmid,
	optional => 1,
    },
    node => get_standard_option('pve-node', {
	description => "Only run if executed on this node.",
	completion => \&PVE::Cluster::get_nodelist,
	optional => 1,
    }),
    all => {
	type => 'boolean',
	description => "Backup all known guest systems on this host.",
	optional => 1,
	default => 0,
    },
    stdexcludes => {
	type => 'boolean',
	description => "Exclude temporary files and logs.",
	optional => 1,
	default => 1,
    },
    compress => {
	type => 'string',
	description => "Compress dump file.",
	optional => 1,
	enum => ['0', '1', 'gzip', 'lzo', 'zstd'],
	default => '0',
    },
    pigz=> {
	type => "integer",
	description => "Use pigz instead of gzip when N>0.".
	    " N=1 uses half of cores, N>1 uses N as thread count.",
	optional => 1,
	default => 0,
    },
    zstd => {
	type => "integer",
	description => "Zstd threads. N=0 uses half of the available cores,".
	    " N>0 uses N as thread count.",
	optional => 1,
	default => 1,
    },
    quiet => {
	type => 'boolean',
	description => "Be quiet.",
	optional => 1,
	default => 0,
    },
    mode => {
	type => 'string',
	description => "Backup mode.",
	optional => 1,
	default => 'snapshot',
	enum => [ 'snapshot', 'suspend', 'stop' ],
    },
    exclude => {
	type => 'string', format => 'pve-vmid-list',
	description => "Exclude specified guest systems (assumes --all)",
	optional => 1,
    },
    'exclude-path' => {
	type => 'string', format => 'string-alist',
	description => "Exclude certain files/directories (shell globs)." .
	    " Paths starting with '/' are anchored to the container's root, " .
	    " other paths match relative to each subdirectory.",
	optional => 1,
    },
    mailto => {
	type => 'string',
	format => 'email-or-username-list',
	description => "Comma-separated list of email addresses or users that should" .
	    " receive email notifications.",
	optional => 1,
    },
    mailnotification => {
	type => 'string',
	description => "Specify when to send an email",
	optional => 1,
	enum => [ 'always', 'failure' ],
	default => 'always',
    },
    tmpdir => {
	type => 'string',
	description => "Store temporary files to specified directory.",
	optional => 1,
    },
    dumpdir => {
	type => 'string',
	description => "Store resulting files to specified directory.",
	optional => 1,
    },
    script => {
	type => 'string',
	description => "Use specified hook script.",
	optional => 1,
    },
    storage => get_standard_option('pve-storage-id', {
	description => "Store resulting file to this storage.",
	completion => \&complete_backup_storage,
	optional => 1,
    }),
    stop => {
	type => 'boolean',
	description => "Stop running backup jobs on this host.",
	optional => 1,
	default => 0,
    },
    bwlimit => {
	type => 'integer',
	description => "Limit I/O bandwidth (KBytes per second).",
	optional => 1,
	minimum => 0,
	default => 0,
    },
    ionice => {
	type => 'integer',
	description => "Set CFQ ionice priority.",
	optional => 1,
	minimum => 0,
	maximum => 8,
	default => 7,
    },
    performance => {
	type => 'string',
	description => "Other performance-related settings.",
	format => 'backup-performance',
	optional => 1,
    },
    lockwait => {
	type => 'integer',
	description => "Maximal time to wait for the global lock (minutes).",
	optional => 1,
	minimum => 0,
	default => 3*60, # 3 hours
    },
    stopwait => {
	type => 'integer',
	description => "Maximal time to wait until a guest system is stopped (minutes).",
	optional => 1,
	minimum => 0,
	default => 10, # 10 minutes
    },
    # FIXME remove with PVE 8.0 or PVE 9.0
    maxfiles => {
	type => 'integer',
	description => "Deprecated: use 'prune-backups' instead. " .
	    "Maximal number of backup files per guest system.",
	optional => 1,
	minimum => 1,
    },
    'prune-backups' => get_standard_option('prune-backups', {
	description => "Use these retention options instead of those from the storage configuration.",
	optional => 1,
	default => "keep-all=1",
    }),
    remove => {
	type => 'boolean',
	description => "Prune older backups according to 'prune-backups'.",
	optional => 1,
	default => 1,
    },
    pool => {
	type => 'string',
	description => 'Backup all known guest systems included in the specified pool.',
	optional => 1,
    },
    'notes-template' => {
	type => 'string',
	description => "Template string for generating notes for the backup(s). It can contain ".
	    "variables which will be replaced by their values. Currently supported are ".
	    "{{cluster}}, {{guestname}}, {{node}}, and {{vmid}}, but more might be added in the ".
	    "future. Needs to be a single line, newline and backslash need to be escaped as '\\n' ".
	    "and '\\\\' respectively.",
	requires => 'storage',
	maxLength => 1024,
	optional => 1,
    },
    protected => {
	type => 'boolean',
	description => "If true, mark backup(s) as protected.",
	requires => 'storage',
	optional => 1,
    },
};

sub get_confdesc {
    return $confdesc;
}

# add JSON properties for create and set function
sub json_config_properties {
    my $prop = shift;

    foreach my $opt (keys %$confdesc) {
	$prop->{$opt} = $confdesc->{$opt};
    }

    return $prop;
}

my $vzdump_properties = {
    additionalProperties => 0,
    properties => json_config_properties({}),
};

sub parse_vzdump_cron_config {
    my ($filename, $raw) = @_;

    my $jobs = []; # correct jobs

    my $ejobs = []; # mailfomerd lines

    my $jid = 1; # we start at 1

    my $digest = Digest::SHA::sha1_hex(defined($raw) ? $raw : '');

    while ($raw && $raw =~ s/^(.*?)(\n|$)//) {
	my $line = $1;

	next if $line =~ m/^\#/;
	next if $line =~ m/^\s*$/;
	next if $line =~ m/^PATH\s*=/; # we always overwrite path

	if ($line =~ m|^(\d+)\s+(\d+)\s+\*\s+\*\s+(\S+)\s+root\s+(/\S+/)?(#)?vzdump(\s+(.*))?$|) {
	    eval {
		my $minute = int($1);
		my $hour = int($2);
		my $dow = $3;
		my $param = $7;
		my $enabled = $5;

		my $dowhash = parse_dow($dow, 1);
		die "unable to parse day of week '$dow' in '$filename'\n" if !$dowhash;

		my $args = PVE::Tools::split_args($param);
		my $opts = PVE::JSONSchema::get_options($vzdump_properties, $args, 'vmid');

		$opts->{enabled} = !defined($enabled);
		$opts->{id} = "$digest:$jid";
		$jid++;
		$opts->{starttime} = sprintf "%02d:%02d", $hour, $minute;
		$opts->{dow} = &$dowhash_to_dow($dowhash);

		parse_property_strings($opts);

		push @$jobs, $opts;
	    };
	    my $err = $@;
	    if ($err) {
		syslog ('err', "parse error in '$filename': $err");
		push @$ejobs, { line => $line };
	    }
	} elsif ($line =~ m|^\S+\s+(\S+)\s+\S+\s+\S+\s+\S+\s+\S+\s+(\S.*)$|) {
	    syslog ('err', "warning: malformed line in '$filename'");
	    push @$ejobs, { line => $line };
	} else {
	    syslog ('err', "ignoring malformed line in '$filename'");
	}
    }

    my $res = {};
    $res->{digest} = $digest;
    $res->{jobs} = $jobs;
    $res->{ejobs} = $ejobs;

    return $res;
}

sub write_vzdump_cron_config {
    my ($filename, $cfg) = @_;

    my $out = "# cluster wide vzdump cron schedule\n";
    $out .= "# Automatically generated file - do not edit\n\n";
    $out .= "PATH=\"/usr/sbin:/usr/bin:/sbin:/bin\"\n\n";

    my $jobs = $cfg->{jobs} || [];
    foreach my $job (@$jobs) {
	my $enabled = ($job->{enabled}) ? '' : '#';
	my $dh = parse_dow($job->{dow});
	my $dow;
	if ($dh->{mon} && $dh->{tue} && $dh->{wed} && $dh->{thu} &&
	    $dh->{fri} && $dh->{sat} && $dh->{sun}) {
	    $dow = '*';
	} else {
	    $dow = &$dowhash_to_dow($dh, 1);
	    $dow = '*' if !$dow;
	}

	my ($hour, $minute);

	die "no job start time specified\n" if !$job->{starttime};
	if ($job->{starttime} =~ m/^(\d{1,2}):(\d{1,2})$/) {
	    ($hour, $minute) = (int($1), int($2));
	    die "hour '$hour' out of range\n" if $hour < 0 || $hour > 23;
	    die "minute '$minute' out of range\n" if $minute < 0 || $minute > 59;
	} else {
	    die "unable to parse job start time\n";
	}

	$job->{quiet} = 1; # we do not want messages from cron

	my $cmd = command_line($job);

	$out .= sprintf "$minute $hour * * %-11s root $enabled$cmd\n", $dow;
    }

    my $ejobs = $cfg->{ejobs} || [];
    foreach my $job (@$ejobs) {
	$out .= "$job->{line}\n" if $job->{line};
    }

    return $out;
}

sub command_line {
    my ($param) = @_;

    my $cmd = "vzdump";

    if ($param->{vmid}) {
	$cmd .= " " . join(' ', PVE::Tools::split_list($param->{vmid}));
    }

    foreach my $p (keys %$param) {
	next if $p eq 'id' || $p eq 'vmid' || $p eq 'starttime' ||
	        $p eq 'dow' || $p eq 'stdout' || $p eq 'enabled';
	my $v = $param->{$p};
	my $pd = $confdesc->{$p} || die "no such vzdump option '$p'\n";
	if ($p eq 'exclude-path') {
	    foreach my $path (split(/\0/, $v || '')) {
		$cmd .= " --$p " . PVE::Tools::shellquote($path);
	    }
	} else {
	    $v = join(",", PVE::Tools::split_list($v)) if $p eq 'mailto';
	    $v = PVE::JSONSchema::print_property_string($v, $PROPERTY_STRINGS->{$p})
		if $PROPERTY_STRINGS->{$p};

	    $cmd .= " --$p " . PVE::Tools::shellquote($v) if defined($v) && $v ne '';
	}
    }

    return $cmd;
}

# bash completion helpers
sub complete_backup_storage {

    my $cfg = PVE::Storage::config();
    my $ids = $cfg->{ids};

    my $nodename = PVE::INotify::nodename();

    my $res = [];
    foreach my $sid (keys %$ids) {
	my $scfg = $ids->{$sid};
	next if !PVE::Storage::storage_check_enabled($cfg, $sid, $nodename, 1);
	next if !$scfg->{content}->{backup};
	push @$res, $sid;
    }

    return $res;
}

1;
