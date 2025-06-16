package PVE::Mapping::Dir;

use strict;
use warnings;

use PVE::Cluster qw(cfs_register_file cfs_read_file cfs_lock_file cfs_write_file);
use PVE::INotify;
use PVE::JSONSchema qw(get_standard_option parse_property_string);
use PVE::SectionConfig;

use base qw(PVE::SectionConfig);

my $FILENAME = 'mapping/directory.cfg';

cfs_register_file(
    $FILENAME,
    sub { __PACKAGE__->parse_config(@_); },
    sub { __PACKAGE__->write_config(@_); },
);

# so we don't have to repeat the type every time
sub parse_section_header {
    my ($class, $line) = @_;

    if ($line =~ m/^(\S+)\s*$/) {
        my $id = $1;
        my $errmsg = undef; # set if you want to skip whole section
        eval { PVE::JSONSchema::pve_verify_configid($id) };
        $errmsg = $@ if $@;
        my $config = {}; # to return additional attributes
        return ('dir', $id, $errmsg, $config);
    }
    return undef;
}

sub format_section_header {
    my ($class, $type, $sectionId, $scfg, $done_hash) = @_;

    return "$sectionId\n";
}

sub type {
    return 'dir';
}

# temporary path format that also disallows commas and equal signs
# TODO: Remove this when property_string supports quotation of properties
PVE::JSONSchema::register_format('pve-storage-path-in-property-string', \&pve_verify_path);

sub pve_verify_path {
    my ($path, $noerr) = @_;

    if ($path !~ m|^/[^;,=\(\)]+|) {
        return undef if $noerr;
        die "Value does not look like a valid absolute path."
            . " These symbols are currently not allowed in path: ;,=()\n";
    }
    return $path;
}

my $map_fmt = {
    node => get_standard_option('pve-node'),
    path => {
        description => "Absolute directory path that should be shared with the guest.",
        type => 'string',
        format => 'pve-storage-path-in-property-string',
    },
};

my $defaultData = {
    propertyList => {
        id => {
            type => 'string',
            description => "The ID of the directory mapping",
            format => 'pve-configid',
        },
        description => {
            type => 'string',
            description => "Description of the directory mapping",
            optional => 1,
            maxLength => 4096,
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
        map => {},
    };
}

sub assert_valid {
    my ($dir_cfg) = @_;

    my $path = $dir_cfg->{path};

    pve_verify_path($path);

    if (!-e $path) {
        die "Path $path does not exist\n";
    } elsif (!-d $path) {
        die "Path $path exists, but is not a directory\n";
    }

    return 1;
}

sub assert_valid_map_list {
    my ($map_list) = @_;

    my $nodename = PVE::INotify::nodename();

    my %count;
    for my $map (@$map_list) {
        my $entry = parse_property_string($map_fmt, $map);
        if ($entry->{node} eq $nodename) {
            assert_valid($entry);
        }
        $count{ $entry->{node} }++;
    }
    for my $node (keys %count) {
        if ($count{$node} > 1) {
            die "Node '$node' is specified $count{$node} times.\n";
        }
    }
}

sub config {
    return cfs_read_file($FILENAME);
}

sub lock_dir_config {
    my ($code, $errmsg) = @_;

    cfs_lock_file($FILENAME, undef, $code);
    if (my $err = $@) {
        $errmsg ? die "$errmsg: $err" : die $err;
    }
}

sub write_dir_config {
    my ($cfg) = @_;

    cfs_write_file($FILENAME, $cfg);
}

sub find_on_current_node {
    my ($id) = @_;

    my $cfg = config();
    my $node = PVE::INotify::nodename();

    my $node_mapping = get_node_mapping($cfg, $id, $node);
    if (!$node_mapping) {
        die "Directory ID $id does not exist.\n";
    }
    if (@{$node_mapping} > 1) {
        die "More than than one directory mapping for node $node.\n";
    } elsif (@{$node_mapping} == 0) {
        die "No directory mapping for node $node.\n";
    }

    return $node_mapping->[0];
}

sub get_node_mapping {
    my ($cfg, $id, $nodename) = @_;

    return undef if !defined($cfg->{ids}->{$id});

    my $res = [];
    my $mapping_list = $cfg->{ids}->{$id}->{map};
    for my $map (@{$mapping_list}) {
        my $entry = eval { parse_property_string($map_fmt, $map) };
        warn $@ if $@;
        if ($entry && $entry->{node} eq $nodename) {
            push $res->@*, $entry;
        }
    }
    return $res;
}

PVE::Mapping::Dir->register();
PVE::Mapping::Dir->init();

1;
