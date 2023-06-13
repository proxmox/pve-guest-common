package PVE::Mapping::USB;

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

my $FILENAME = 'mapping/usb.cfg';

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
	return ('usb', $id, $errmsg, $config);
    }
    return undef;
}

sub format_section_header {
    my ($class, $type, $sectionId, $scfg, $done_hash) = @_;

    return "$sectionId\n";
}

sub type {
    return 'usb';
}

my $map_fmt = {
    node => get_standard_option('pve-node'),
    'id' => {
	description => "The vendor and device ID that is expected. If a USB path"
	." is given, it is only used for detecting hardware changes",
	type => 'string',
	pattern => qr/^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}$/,
    },
    path => {
	description => "The path to the usb device.",
	type => 'string',
	optional => 1,
	pattern => qr/^(\d+)\-(\d+(\.\d+)*)$/,
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
	    description => "The ID of the logical USB mapping.",
	    format => 'pve-configid',
	},
	description => {
	    description => "Description of the logical USB device.",
	    type => 'string',
	    optional => 1,
	    maxLength => 4096,
	},
	map => {
	    type => 'array',
	    description => 'A list of maps for the cluster nodes.',
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
	map => {},
    };
}

# checks if the given device is valid for the current node
sub assert_valid {
    my ($name, $cfg) = @_;

    my $id = $cfg->{id};

    my $usb_list = PVE::SysFSTools::scan_usb();

    my $info;
    if (my $path = $cfg->{path}) {
	for my $dev (@$usb_list) {
	    next if !$dev->{usbpath} || !$dev->{busnum};
	    my $usbpath = "$dev->{busnum}-$dev->{usbpath}";
	    next if $usbpath ne $path;
	    $info = $dev;
	}
	die "usb device '$path' not found\n" if !defined($info);

	my $realId = "$info->{vendid}:$info->{prodid}";
	die "'id' does not match for '$name' ($realId != $id)\n"
	    if $realId ne $id;
    } else {
	for my $dev (@$usb_list) {
	    my $realId = "$dev->{vendid}:$dev->{prodid}";
	    next if $realId ne $id;
	    $info = $dev;
	}
	die "usb device '$id' not found\n" if !defined($info);
    }

    return 1;
};

sub config {
    return cfs_read_file($FILENAME);
}

sub lock_usb_config {
    my ($code, $errmsg) = @_;

    cfs_lock_file($FILENAME, undef, $code);
    if (my $err = $@) {
	$errmsg ? die "$errmsg: $err" : die $err;
    }
}

sub write_usb_config {
    my ($cfg) = @_;

    cfs_write_file($FILENAME, $cfg);
}

sub find_on_current_node {
    my ($id) = @_;

    my $cfg = config();
    my $node = PVE::INotify::nodename();

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

PVE::Mapping::USB->register();
PVE::Mapping::USB->init();

1;
