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

PVE::JSONSchema::register_standard_option('pve-replication-id', {
    description => "Replication Job ID.",
    type => 'string', format => 'pve-configid',
    maxLength => 32, # keep short to reduce snapshot name length
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
	guest => get_standard_option('pve-vmid', {
	    optional => 1,
	    completion => \&PVE::Cluster::complete_vmid }),
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
    },
};

sub private {
    return $defaultData;
}

sub parse_section_header {
    my ($class, $line) = @_;

    if ($line =~ m/^(\S+):\s*(\S+)\s*$/) {
	my ($type, $id) = (lc($1), $2);
	my $errmsg = undef; # set if you want to skip whole section
	eval { PVE::JSONSchema::pve_verify_configid($id); };
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
	guest => { fixed => 1, optional => 0 },
	target => { fixed => 1, optional => 0 },
	disable => { optional => 1 },
	comment => { optional => 1 },
	rate => { optional => 1 },
	schedule => { optional => 1 },
    };
}

sub get_unique_target_id {
    my ($class, $data) = @_;

    return "local/$data->{target}";
}

PVE::ReplicationConfig::Cluster->register();
PVE::ReplicationConfig->init();

1;
