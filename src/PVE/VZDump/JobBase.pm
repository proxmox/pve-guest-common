package PVE::VZDump::JobBase;

use strict;
use warnings;

use PVE::JSONSchema;

use PVE::VZDump::Common;

use base qw(PVE::Job::Registry);

sub type {
    return 'vzdump';
}

my $props = PVE::VZDump::Common::json_config_properties();

sub properties {
    return $props;
}

sub options {
    my $options = {
	enabled => { optional => 1 },
	schedule => {},
	comment => { optional => 1 },
	'repeat-missed' => { optional => 1 },
    };
    foreach my $opt (keys %$props) {
	if ($props->{$opt}->{optional}) {
	    $options->{$opt} = { optional => 1 };
	} else {
	    $options->{$opt} = {};
	}
    }

    return $options;
}

sub decode_value {
    my ($class, $type, $key, $value) = @_;

    if ((my $format = $PVE::VZDump::Common::PROPERTY_STRINGS->{$key}) && !ref($value)) {
	$value = PVE::JSONSchema::parse_property_string($format, $value);
    }

    return $value;
}

sub encode_value {
    my ($class, $type, $key, $value) = @_;

    if ((my $format = $PVE::VZDump::Common::PROPERTY_STRINGS->{$key}) && ref($value) eq 'HASH') {
	$value = PVE::JSONSchema::print_property_string($value, $format);
    }

    return $value;
}

sub run {
    my ($class, $conf) = @_;
    die "config base class, implement me in sub class"
}

1;
