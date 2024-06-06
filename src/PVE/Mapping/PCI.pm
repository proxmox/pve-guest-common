package PVE::Mapping::PCI;

use strict;
use warnings;

use PVE::Cluster qw(
    cfs_lock_file
    cfs_read_file
    cfs_register_file
    cfs_write_file
);
use PVE::INotify ();
use PVE::JSONSchema qw(get_standard_option parse_property_string);
use PVE::SysFSTools ();

use base qw(PVE::SectionConfig);

my $FILENAME = 'mapping/pci.cfg';

cfs_register_file($FILENAME,
		  sub { __PACKAGE__->parse_config(@_); },
		  sub { __PACKAGE__->write_config(@_); });


# so we don't have to repeat the type every time
sub parse_section_header {
    my ($class, $line) = @_;

    if ($line =~ m/^(\S+)\s*$/) {
	my $id = $1;
	my $errmsg = undef; # set if you want to skip whole section
	eval { PVE::JSONSchema::pve_verify_configid($id) };
	$errmsg = $@ if $@;
	my $config = {}; # to return additional attributes
	return ('pci', $id, $errmsg, $config);
    }
    return undef;
}

sub format_section_header {
    my ($class, $type, $sectionId, $scfg, $done_hash) = @_;

    return "$sectionId\n";
}

sub type {
    return 'pci';
}

my $PCI_RE = "[a-f0-9]{4,}:[a-f0-9]{2}:[a-f0-9]{2}(?:\.[a-f0-9])?";

my $map_fmt = {
    node => get_standard_option('pve-node'),
    id =>{
	description => "The vendor and device ID that is expected. Used for"
	." detecting hardware changes",
	type => 'string',
	pattern => qr/^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}$/,
    },
    'subsystem-id' => {
	description => "The subsystem vendor and device ID that is expected. Used"
	." for detecting hardware changes.",
	type => 'string',
	pattern => qr/^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}$/,
	optional => 1,
    },
    path => {
	description => "The path to the device. If the function is omitted, the whole device is"
	." mapped. In that case use the attributes of the first device. You can give"
	." multiple paths as a semicolon seperated list, the first available will then"
	." be chosen on guest start.",
	type => 'string',
	pattern => "(?:${PCI_RE};)*${PCI_RE}",
    },
    iommugroup => {
	type => 'integer',
	description => "The IOMMU group in which the device is to be expected in."
	." Used for detecting hardware changes.",
	optional => 1,
    },
    description => {
	description => "Description of the node specific device.",
	type => 'string',
	optional => 1,
	maxLength => 4096,
    },
};

my $defaultData = {
    propertyList => {
	id => {
	    type => 'string',
	    description => "The ID of the logical PCI mapping.",
	    format => 'pve-configid',
	},
	description => {
	    description => "Description of the logical PCI device.",
	    type => 'string',
	    optional => 1,
	    maxLength => 4096,
	},
	mdev => {
	    description => "Marks the device(s) as being capable of providing mediated devices.",
	    type => 'boolean',
	    optional => 1,
	    default => 0,
	},
	map => {
	    type => 'array',
	    description => 'A list of maps for the cluster nodes.',
	    optional => 1,
	    items => {
		type => 'string',
		format => $map_fmt,
	    },
	},
    },
};

sub private {
    return $defaultData;
}

sub options {
    return {
	description => { optional => 1 },
	mdev => { optional => 1 },
	map => {},
    };
}

# checks if the given config is valid for the current node
sub assert_valid {
    my ($name, $mapping) = @_;

    my @paths = split(';', $mapping->{path} // '');

    my $idx = 0;
    for my $path (@paths) {

	my $multifunction = 0;
	if ($path !~ m/\.[a-f0-9]/i) {
	    # whole device, add .0 (must exist)
	    $path = "$path.0";
	    $multifunction = 1;
	}

	my $info = PVE::SysFSTools::pci_device_info($path, 1);
	die "pci device '$path' not found\n" if !defined($info);

	# make sure to initialize all keys that should be checked below
	my $expected_props = {
	    id => "$info->{vendor}:$info->{device}",
	    iommugroup => $info->{iommugroup},
	    'subsystem-id' => undef,
	};

	if (defined($info->{'subsystem_vendor'}) && defined($info->{'subsystem_device'})) {
	    $expected_props->{'subsystem-id'} = "$info->{'subsystem_vendor'}:$info->{'subsystem_device'}";
	}

	my $configured_props = { $mapping->%{qw(id iommugroup subsystem-id)} };

	for my $prop (sort keys $expected_props->%*) {
	    next if $prop eq 'iommugroup' && $idx > 0; # check iommu only on the first device

	    next if !defined($expected_props->{$prop}) && !defined($configured_props->{$prop});
	    die "missing expected property '$prop' for device '$path'\n"
		if defined($expected_props->{$prop}) && !defined($configured_props->{$prop});
	    die "unexpected property '$prop' configured for device '$path'\n"
		if !defined($expected_props->{$prop}) && defined($configured_props->{$prop});

	    my $expected_prop = $expected_props->{$prop};
	    $expected_prop =~ s/0x//g;
	    my $configured_prop = $configured_props->{$prop};
	    $configured_prop =~ s/0x//g;

	    die "'$prop' does not match for '$name' ($expected_prop != $configured_prop)\n"
		if $expected_prop ne $configured_prop;
	}

	$idx++;
    }

    return 1;
};

sub config {
    return cfs_read_file($FILENAME);
}

sub lock_pci_config {
    my ($code, $errmsg) = @_;

    cfs_lock_file($FILENAME, undef, $code);
    if (my $err = $@) {
	$errmsg ? die "$errmsg: $err" : die $err;
    }
}

sub write_pci_config {
    my ($cfg) = @_;

    cfs_write_file($FILENAME, $cfg);
}

sub find_on_current_node {
    my ($id) = @_;

    my $cfg = PVE::Mapping::PCI::config();
    my $node = PVE::INotify::nodename();

    # ignore errors
    return get_node_mapping($cfg, $id, $node);
}

sub get_node_mapping {
    my ($cfg, $id, $nodename) = @_;

    return undef if !defined($cfg->{ids}->{$id});

    my $res = [];
    for my $map ($cfg->{ids}->{$id}->{map}->@*) {
	my $entry = eval { parse_property_string($map_fmt, $map) };
	warn $@ if $@;
	if ($entry && $entry->{node} eq $nodename) {
	    push $res->@*, $entry;
	}
    }

    return $res;
}

PVE::Mapping::PCI->register();
PVE::Mapping::PCI->init();

1;
