package PVE::ReplicationConfig;

use strict;
use warnings;
use Data::Dumper;

use PVE::Tools;
use PVE::JSONSchema qw(get_standard_option);
use PVE::INotify;
use PVE::SectionConfig;
use PVE::CalendarEvent;

use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_write_file cfs_lock_file);

use base qw(PVE::SectionConfig);

my $replication_cfg_filename = 'replication.cfg';

cfs_register_file($replication_cfg_filename,
		  sub { __PACKAGE__->parse_config(@_); },
		  sub { __PACKAGE__->write_config(@_); });

PVE::JSONSchema::register_format('pve-replication-job-id',
				 \&parse_replication_job_id);
sub parse_replication_job_id {
    my ($id, $noerr) = @_;

    my $msg = "invalid replication job id '$id'";

    if ($id =~ m/^(\d+)-(\d+)$/) {
	my ($guest, $jobnum) = (int($1), int($2));
	die "$msg (guest IDs < 100 are reseved)\n" if $guest < 100;
	my $parsed_id = "$guest-$jobnum"; # use parsed integers
	return wantarray ? ($guest, $jobnum, $parsed_id) :  $parsed_id;
    }

    return undef if $noerr;

    die "$msg\n";
}

PVE::JSONSchema::register_standard_option('pve-replication-id', {
    description => "Replication Job ID. The ID is composed of a Guest ID and a job number, separated by a hyphen, i.e. '<GUEST>-<JOBNUM>'.",
    type => 'string', format => 'pve-replication-job-id',
    pattern => '[1-9][0-9]{2,8}-\d{1,9}',
});

my $defaultData = {
    propertyList => {
	type => { description => "Section type." },
	id => get_standard_option('pve-replication-id'),
	disable => {
	    description => "Flag to disable/deactivate the entry.",
	    type => 'boolean',
	    optional => 1,
	},
	comment => {
	    description => "Description.",
	    type => 'string',
	    optional => 1,
	    maxLength => 4096,
	},
	remove_job => {
	    description => "Mark the replication job for removal. The job will remove all local replication snapshots. When set to 'full', it also tries to remove replicated volumes on the target. The job then removes itself from the configuration file.",
	    type => 'string',
	    enum => ['local', 'full'],
	    optional => 1,
	},
	rate => {
	    description => "Rate limit in mbps (megabytes per second) as floating point number.",
	    type => 'number',
	    minimum => 1,
	    optional => 1,
	},
	schedule => {
	    description => "Storage replication schedule. The format is a subset of `systemd` calender events.",
	    type => 'string', format => 'pve-calendar-event',
	    maxLength => 128,
	    default => '*/15',
	    optional => 1,
	},
	source => {
	    description => "Source of the replication.",
	    type => 'string', format => 'pve-node',
	    optional => 1,
	},
    },
};

sub private {
    return $defaultData;
}

sub parse_section_header {
    my ($class, $line) = @_;

    if ($line =~ m/^(\S+):\s*(\d+)-(\d+)\s*$/) {
	my ($type, $guest, $subid) = (lc($1), int($2), int($3));
	my $id = "$guest-$subid"; # use parsed integers
	my $errmsg = undef; # set if you want to skip whole section
	eval { parse_replication_job_id($id); };
	$errmsg = $@ if $@;
	my $config = {};
	return ($type, $id, $errmsg, $config);
    }
    return undef;
}

# Note: We want only one replication job per target to
# avoid confusion. This method should return a string
# which uniquely identifies the target.
sub get_unique_target_id {
    my ($class, $data) = @_;

    die "please overwrite in subclass";
}

sub parse_config {
    my ($class, $filename, $raw) = @_;

    my $cfg = $class->SUPER::parse_config($filename, $raw);

    my $target_hash = {};

    foreach my $id (sort keys %{$cfg->{ids}}) {
	my $data = $cfg->{ids}->{$id};

	my ($guest, $jobnum) = parse_replication_job_id($id);

	$data->{guest} = $guest;
	$data->{jobnum} = $jobnum;
	$data->{id} = $id;

	$data->{comment} = PVE::Tools::decode_text($data->{comment})
	    if defined($data->{comment});

	my $plugin = $class->lookup($data->{type});
	my $tid = $plugin->get_unique_target_id($data);
	my $vmid = $data->{guest};

	# should not happen, but we want to be sure
	if (defined($target_hash->{$vmid}->{$tid})) {
	    warn "delete job $id: replication job for guest '$vmid' to target '$tid' already exists\n";
	    delete $cfg->{ids}->{$id};
	}
	$target_hash->{$vmid}->{$tid} = 1;
   }

    return $cfg;
}

sub write_config {
    my ($class, $filename, $cfg) = @_;

    my $target_hash = {};

    foreach my $id (keys %{$cfg->{ids}}) {
	my $data = $cfg->{ids}->{$id};

	my $plugin = $class->lookup($data->{type});
	my $tid = $plugin->get_unique_target_id($data);
	my $vmid = $data->{guest};

	die "property 'guest' has wrong value\n" if $id !~ m/^\Q$vmid\E-/;
	die "replication job for guest '$vmid' to target '$tid' already exists\n"
	    if defined($target_hash->{$vmid}->{$tid});
	$target_hash->{$vmid}->{$tid} = 1;

	$data->{comment} = PVE::Tools::encode_text($data->{comment})
	    if defined($data->{comment});
    }

    $class->SUPER::write_config($filename, $cfg);
}

sub new {
    my ($type) = @_;

    my $class = ref($type) || $type;

    my $cfg = cfs_read_file($replication_cfg_filename);

    return bless $cfg, $class;
}

sub write {
    my ($cfg) = @_;

    cfs_write_file($replication_cfg_filename, $cfg);
}

sub lock {
    my ($code, $errmsg) = @_;

    cfs_lock_file($replication_cfg_filename, undef, $code);
    my $err = $@;
    if ($err) {
	$errmsg ? die "$errmsg: $err" : die $err;
    }
}

sub check_for_existing_jobs {
    my ($cfg, $vmid, $noerr) = @_;

    foreach my $id (keys %{$cfg->{ids}}) {
	my $data = $cfg->{ids}->{$id};

	if ($data->{guest} == $vmid) {
	    return 1 if $noerr;
	    die "There is a replication job '$id' for guest '$vmid' - " .
		"Please remove that first.\n"
	}
    }

    return undef;
}

sub find_local_replication_job {
    my ($cfg, $vmid, $target) = @_;

    foreach my $id (keys %{$cfg->{ids}}) {
	my $data = $cfg->{ids}->{$id};

	return $data if $data->{type} eq 'local' &&
	    $data->{guest} == $vmid && $data->{target} eq $target;
    }

    return undef;
}

# switch local replication job target
sub switch_replication_job_target {
    my ($vmid, $old_target, $new_target) = @_;

    my $transfer_job = sub {
	my $cfg = PVE::ReplicationConfig->new();
	my $jobcfg = find_local_replication_job($cfg, $vmid, $old_target);

	return if !$jobcfg;

	$jobcfg->{target} = $new_target;

	$cfg->write();
    };

    lock($transfer_job);
};

sub delete_job {
    my ($jobid) = @_;

    my $code = sub {
	my $cfg = __PACKAGE__->new();
	delete $cfg->{ids}->{$jobid};
	$cfg->write();
    };

    lock($code);
}

sub swap_source_target_nolock {
    my ($jobid) = @_;

    my $cfg = __PACKAGE__->new();
    my $job = $cfg->{ids}->{$jobid};
    my $tmp = $job->{source};
    $job->{source} = $job->{target};
    $job->{target} = $tmp;
    $cfg->write();

    return $cfg->{ids}->{$jobid};
}

package PVE::ReplicationConfig::Cluster;

use base qw(PVE::ReplicationConfig);

sub type {
    return 'local';
}

sub properties {
    return {
	target => {
	    description => "Target node.",
	    type => 'string', format => 'pve-node',
	},
    };
}

sub options {
    return {
	target => { fixed => 1, optional => 0 },
	disable => { optional => 1 },
	comment => { optional => 1 },
	rate => { optional => 1 },
	schedule => { optional => 1 },
	remove_job => { optional => 1 },
	source => { optional => 1 },
    };
}

sub get_unique_target_id {
    my ($class, $data) = @_;

    return "local/$data->{target}";
}

PVE::ReplicationConfig::Cluster->register();
PVE::ReplicationConfig->init();

1;
