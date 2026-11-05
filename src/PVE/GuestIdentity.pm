package PVE::GuestIdentity;

use v5.36;

use Time::HiRes;

use PVE::Cluster;

# The identity of a guest, VM or container alike, consists of two members of the 'meta' property
# string in the top-level section of its config: 'uid', a random identifier of the guest (100 bits
# as 20 characters of the lowercase RFC 4648 base32 alphabet), and 'rtime', the time the config was
# registered in this cluster (milliseconds since the epoch). The functions here pass it as a hash
# with these two keys.
#
# 100 random bits make a duplicate uid practically impossible: a billion uids contain one with a
# probability of about 4 * 10^-13. They also leave 28 bits of a 128-bit value free, for example for
# a format version and extra data, should a later format need them. Base32 keeps the uid at 20
# characters, about half the width of a UUID in its usual notation, and only uses lowercase letters
# and digits, which need no quoting in a property string.
#
# Unlike the creation time 'ctime' of the same property, which a clone, a restore and a migration
# from another cluster copy along with the guest, the rtime belongs to the uid of the guest in this
# cluster: it is the time the guest got its uid here, be it a new one or one it adopted. So a
# changed rtime tells that a guest was registered again, even if its uid is the same as before.

# Must match the first pve-manager release that depends on the qemu-server and pve-container
# versions handling the identity. Older nodes drop the whole 'meta' property on their next write
# of a guest config.
use constant MIN_PVE_MANAGER_VERSION => '9.2.33';

my $UID_LENGTH = 20;
my $UID_ALPHABET = 'abcdefghijklmnopqrstuvwxyz234567';
my $UID_PATTERN = "[a-z2-7]{$UID_LENGTH}";

# 15 digits of milliseconds last until the year 33658
my $RTIME_MAX = 999_999_999_999_999;

# Returns $len random bytes from the kernel's random number generator.
sub __random_bytes($len) {
    open(my $fh, '<', '/dev/urandom') or die "unable to open /dev/urandom - $!\n";
    my $buf = '';
    my $read = sysread($fh, $buf, $len);
    die "unable to read from /dev/urandom - $!\n" if !defined($read);
    die "short read from /dev/urandom\n" if $read != $len;
    close($fh);

    return $buf;
}

# Returns the current time in milliseconds since the epoch.
sub __time_ms() {
    my ($sec, $usec) = Time::HiRes::gettimeofday();

    return $sec * 1000 + int($usec / 1000);
}

# Returns a random uid. Each character comes from the lowest 5 bits of a random byte of its own, so
# it is uniformly distributed over the alphabet.
my sub random_uid() {
    my $bytes = __random_bytes($UID_LENGTH);

    return join('', map { substr($UID_ALPHABET, ord($_) & 31, 1) } split(//, $bytes));
}

my sub is_valid_uid($uid) {
    return defined($uid) && $uid =~ m/^$UID_PATTERN\z/;
}

my sub is_valid_rtime($rtime) {
    return defined($rtime) && $rtime =~ m/^[0-9]{1,15}\z/;
}

# Returns the JSON schema properties of the identity members, for merging into the format of the
# 'meta' property string of a guest type. Every call returns a new copy.
sub meta_format_properties() {
    return {
        uid => {
            type => 'string',
            pattern => $UID_PATTERN,
            description => "Random identifier of the guest, kept across restores and migrations"
                . " and independent of the VMID.",
            optional => 1,
        },
        rtime => {
            type => 'integer',
            minimum => 0,
            maximum => $RTIME_MAX,
            description => "Time the guest was registered in this cluster, for example by"
                . " creation, a restore to a free VMID, or a migration from another cluster, in"
                . " milliseconds since the UNIX epoch.",
            optional => 1,
        },
    };
}

# Returns a new identity with the current time as rtime. Its uid is $uid if given, otherwise a
# random one.
sub new_identity($uid = undef) {
    die "invalid guest identity uid '$uid'\n" if defined($uid) && !is_valid_uid($uid);

    return {
        uid => $uid // random_uid(),
        rtime => __time_ms(),
    };
}

# Extracts the identity from the 'meta' property string $meta, which may contain any other
# members, including ones unknown to this version.
#
# Returns undef if $meta has no valid uid, and an identity otherwise. Its rtime is undef if the
# rtime member is missing or invalid. A member given more than once counts as invalid.
#
# This does not use PVE::JSONSchema::parse_property_string on purpose. That parser rejects the
# whole string if one member is unknown or invalid. A guest without a readable identity gets a new
# one with the next config write, so a problem with another member must not hide the uid.
sub parse_identity($meta) {
    return undef if !defined($meta);

    my $values = {};
    for my $part (split(/,/, $meta)) {
        my ($key, $value) = $part =~ m/^([^=]+)=(.*)\z/ or next;
        next if $key ne 'uid' && $key ne 'rtime';
        $values->{$key} = exists($values->{$key}) ? undef : $value;
    }

    return undef if !is_valid_uid($values->{uid});

    return {
        uid => $values->{uid},
        rtime => is_valid_rtime($values->{rtime}) ? $values->{rtime} : undef,
    };
}

# Returns the 'meta' property string $meta, which may be undef, with the identity members set to
# $identity. All other members are kept as they are, also ones unknown to this version, which
# PVE::JSONSchema::print_property_string would reject.
sub merge_identity($meta, $identity) {
    die "invalid guest identity uid\n" if !is_valid_uid($identity->{uid});
    die "invalid guest identity rtime\n" if !is_valid_rtime($identity->{rtime});

    my (@plain, @members);
    for my $part (split(/,/, $meta // '')) {
        next if $part =~ m/^\s*\z/;

        if (my ($key) = $part =~ m/^([^=]+)=/) {
            push @members, [$key, $part] if $key ne 'uid' && $key ne 'rtime';
        } else {
            push @plain, $part;
        }
    }
    push @members, ['rtime', "rtime=$identity->{rtime}"], ['uid', "uid=$identity->{uid}"];

    # same order as PVE::JSONSchema::print_property_string uses, so that a guest type parsing and
    # printing the property string again does not change it
    return join(',', @plain, map { $_->[1] } sort { $a->[0] cmp $b->[0] } @members);
}

# Returns the identity in the top-level section of the raw guest config $raw, undef if it has none.
# Only looks at the 'meta' property, so this also finds the identity in a config that the parser of
# the guest type rejects or reads without 'meta', for example because of members from a newer
# version.
#
# If a manual edit left more than one 'meta' line, the last one with anything after the colon
# counts, also if that is only whitespace. The property lookup of pmxcfs does the same, and the
# cluster-wide check of adopt uses it.
sub parse_identity_from_raw_config($raw) {
    my $meta;
    for my $line (split(/\n/, $raw)) {
        last if $line =~ m/^\[/; # snapshot or other section
        $meta = $1 =~ s/^\s+|\s+$//gr if $line =~ m/^meta:(.+)$/;
    }

    return parse_identity($meta);
}

# Returns undef if $node runs a version of Proxmox VE that keeps the identity when writing guest
# configs, see MIN_PVE_MANAGER_VERSION. Missing or invalid version information counts as too old.
# Otherwise returns a hash with 'required-version', the minimum version, and 'version', the version
# the node reports, if any.
sub node_identity_unsupported($node) {
    my $required = MIN_PVE_MANAGER_VERSION;
    my ($major, $minor, $release) = split(/\./, $required);

    my $supported =
        eval { PVE::Cluster::node_pvecfg_version_at_least($node, $major, $minor, $release) };
    return undef if $supported;

    my $version = eval { PVE::Cluster::get_node_pvecfg_version($node) };

    return { 'required-version' => $required, defined($version) ? (version => $version) : () };
}

# Returns the JSON schema of what node_identity_unsupported returns for a refused node, for the
# result of API calls that report why a node is not allowed as migration target. Every call returns
# a new copy.
sub node_identity_unsupported_schema() {
    return {
        description =>
            "Set if migrating to the node is refused because the node does not report a"
            . " Proxmox VE version that keeps the guest identity.",
        type => 'object',
        optional => 1,
        properties => {
            version => {
                description => "The Proxmox VE version the node reports.",
                type => 'string',
                optional => 1,
            },
            'required-version' => {
                description => "The minimum Proxmox VE version that keeps the guest identity.",
                type => 'string',
            },
        },
    };
}

# Dies unless $node runs a version of Proxmox VE that keeps the identity when writing guest
# configs, see node_identity_unsupported.
sub assert_node_supports_identity($node) {
    my $unsupported = node_identity_unsupported($node) or return;
    my ($version, $required) = $unsupported->@{qw(version required-version)};

    if (!defined($version)) {
        die "node '$node' does not report its Proxmox VE version, so it is unknown whether the node"
            . " keeps the guest identity\n";
    }

    die "node '$node' runs Proxmox VE $version, keeping the guest identity requires $required or"
        . " newer - upgrade the node first\n";
}

1;
