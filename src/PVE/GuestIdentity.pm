package PVE::GuestIdentity;

use v5.36;

use Time::HiRes;

use PVE::Cluster;
use PVE::JSONSchema;
use PVE::RESTEnvironment;

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

# A restore adopts a uid in three steps. An incoming remote migration does the same without step 2:
# it calls adopt right after the reservation, before anything of the guest gets transferred, so that
# a uid in use by another guest can still stop the migration. Its later config writes keep the
# identity, as every config write does, see PVE::AbstractConfig::write_config.
#
# 1. Reserve: create_and_lock_config of the config class writes the config. The guest then has an
#    identity, the one it had before or a new one. The returned reservation records which
#    identity the guest had before, if any, and which one it has now.
# 2. Remember: when the restore knows the uid of the backup, it calls prepare_restore, which stores
#    that uid as pending uid if step 3 could adopt it. It stores the uid with 'unique' as well,
#    although step 3 then does not adopt it. The pending uid is a pending change of 'meta' with only
#    the uid member. It does not count as in use, and no config write applies it. If the restore
#    fails, the guest that it leaves behind still has the pending uid, so a retry can adopt the uid.
# 3. Adopt: at its end, the restore calls adopt. The guest gets the uid if it had no identity
#    before step 1, or had the same uid as pending uid, and if no other guest in the cluster has
#    that uid. Otherwise, the guest keeps the identity it has after step 1.

# Returns the pending uid in the parsed config $conf, undef if there is none.
sub get_pending_uid($conf) {
    my $pending = $conf->{pending} ? parse_identity($conf->{pending}->{meta}) : undef;

    return $pending ? $pending->{uid} : undef;
}

# Sets $uid as pending uid in the parsed config $conf, replacing any pending change of 'meta', or
# removes such a change if $uid is undef.
sub set_pending_uid($conf, $uid) {
    if (defined($uid)) {
        die "invalid guest identity uid '$uid'\n" if !is_valid_uid($uid);
        $conf->{pending}->{meta} = "uid=$uid";
    } elsif ($conf->{pending}) {
        delete $conf->{pending}->{meta};
    }

    return;
}

# Returns $uid if adopt would try to make it the uid of the guest that the operation reserved with
# $reservation. That is the case if the guest had no identity before the operation, or had $uid as
# pending uid. Returns undef otherwise, or if $uid is undef.
my sub adoptable_uid($reservation, $uid) {
    return undef if !defined($uid);
    return $uid
        if !$reservation->{previous} || ($reservation->{'previous-pending-uid'} // '') eq $uid;

    return undef;
}

PVE::JSONSchema::register_standard_option(
    'pve-guest-allow-identity-mismatch',
    {
        type => 'boolean',
        description => "Allow overwriting an existing guest with a backup of another guest, as"
            . " detected by a different 'uid' in 'meta'. The guest then keeps its own uid. Not"
            . " needed to restore a backup again over a guest that an unfinished restore of that"
            . " backup left behind.",
        optional => 1,
        default => 0,
    },
);

# Step 2 of a restore, see above. $backup_uid is the uid of the backup, or undef if it has none. The
# restore overwrites the guest $vmid of the config class $class and reserved it with $reservation.
# This checks $backup_uid against that guest and stores it as pending uid if adopt could make it the
# uid of the guest. The caller must hold the config lock of $vmid. Without $allow_mismatch, this
# must run before the restore changes anything else of the guest.
#
# If the guest had another uid before the restore, and did not have $backup_uid as pending uid
# either, the backup most likely belongs to another guest. This then dies. With $allow_mismatch, it
# only logs that and the guest keeps its uid.
#
# Returns the pending uid, undef if there is none. Until the restore calls adopt, it has to keep the
# pending uid in every config that it writes, see set_pending_uid, also with 'unique', which only
# keeps the restore itself from adopting the uid.
sub prepare_restore($class, $vmid, $reservation, $backup_uid, $allow_mismatch) {
    return undef if !$reservation || !defined($backup_uid);

    my $target = $reservation->{previous};
    my $pending_uid = adoptable_uid($reservation, $backup_uid);

    if ($target && !defined($pending_uid) && $target->{uid} ne $backup_uid) {
        my $guest_type = $class->guest_type();
        if (!$allow_mismatch) {
            die "backup belongs to another guest: its uid '$backup_uid' differs from uid"
                . " '$target->{uid}' of the existing $guest_type $vmid - use"
                . " 'allow-identity-mismatch' to overwrite the $guest_type anyway\n";
        }

        print "guest identity: ignoring backup uid $backup_uid, $guest_type $vmid keeps uid"
            . " $target->{uid}\n";
    }

    $class->record_pending_uid($vmid, $pending_uid) if defined($pending_uid);

    return $pending_uid;
}

my sub try_adopt($class, $vmid, $uid, $reservation) {
    my $outcome = sub($result, $current_uid, @extra) {
        return { result => $result, uid => $current_uid, requested => $uid, @extra };
    };

    my $previous = $reservation->{previous};
    return $outcome->('kept', $previous->{uid}) if $previous && !adoptable_uid($reservation, $uid);

    my $assigned_uid = $reservation->{assigned}->{uid};
    return $outcome->('skipped', $assigned_uid) if !defined($uid);

    # Shared by all guest types, as they share the VMID and uid namespaces. Lock order: the config
    # lock of the guest, then this lock.
    my $res = PVE::Cluster::cfs_lock_domain(
        'guest-identity',
        undef,
        sub {
            my $metas = PVE::Cluster::get_guest_config_properties(['meta']);

            my $current = parse_identity($metas->{$vmid} ? $metas->{$vmid}->{meta} : undef);
            return $outcome->('kept', $uid) if $current && $current->{uid} eq $uid;

            for my $other (sort { $a <=> $b } keys %$metas) {
                my $identity = parse_identity($metas->{$other}->{meta});
                next if !$identity || $identity->{uid} ne $uid;

                my $current_uid = $current ? $current->{uid} : undef;
                return $outcome->('in-use', $current_uid, 'in-use-by' => $other);
            }

            $class->__identity_replace($vmid, new_identity($uid));

            return $outcome->('adopted', $uid);
        },
    );
    die $@ if $@;

    return $res;
}

# Makes $uid, for example the one of a restored backup or of the source guest of a remote
# migration, the uid of the guest $vmid, with the current time as rtime, where the rules below
# allow that.
#
# $class is the config class of the guest and must have guest identities enabled. $reservation is
# what create_and_lock_config returned for the operation. The caller must still hold the config
# lock of $vmid. A restore calls this after its final config write, as its writes keep the pending
# uid until then. $uid can be undef if there is nothing to adopt, for example for a backup without
# uid.
#
# A guest that had an identity before the operation keeps it, unless it had $uid as pending uid.
# Otherwise, $uid replaces the identity that the guest has since the reservation, but only if no
# other guest in the cluster has $uid.
#
# Each result listed below is final, so adopt then removes the pending uid from the config. If the
# cluster-wide identity lock cannot be taken, for example without quorum, there is no result: adopt
# dies and the pending uid stays, so that a later operation can still adopt it.
#
# Returns a hash with the keys 'result', 'uid' (the uid of $vmid afterwards), 'requested' ($uid)
# and, for the result 'in-use', 'in-use-by' (the lowest VMID of the other guests with $uid). The
# result is one of:
#   kept     - the guest had an identity before the operation and keeps it, or it already has $uid
#   adopted  - the guest now has $uid
#   in-use   - another guest has $uid, so the guest keeps the identity of the reservation
#   skipped  - $uid is undef, so the guest keeps the identity of the reservation
sub adopt($class, $vmid, $uid, $reservation) {
    die "guest identities are not enabled for this guest type\n" if !$class->__identity_enabled();
    die "missing guest identity reservation\n"
        if ref($reservation) ne 'HASH' || !$reservation->{assigned};
    die "invalid guest identity uid '$uid'\n" if defined($uid) && !is_valid_uid($uid);

    my $res = try_adopt($class, $vmid, $uid, $reservation);

    # the config write that adopts a uid removes the pending uid, too
    if ($res->{result} ne 'adopted') {
        eval { $class->record_pending_uid($vmid, undef) };
        die "unable to remove the pending uid - $@" if $@;
    }

    return $res;
}

# Returns the task log line for the result $res of adopt, so that all guest types use the same
# wording. $origin names where the requested uid comes from.
my sub adopt_result_message($res, $origin) {
    my ($result, $requested) = $res->@{qw(result requested)};
    my $uid = $res->{uid} // 'none';

    return "guest identity: kept uid $uid" if $result eq 'kept';
    return "guest identity: adopted uid $uid from the $origin" if $result eq 'adopted';
    return "guest identity: new uid $uid" if $result eq 'skipped';

    return "guest identity: $origin uid $requested is in use by guest $res->{'in-use-by'}, keeping"
        . " uid $uid";
}

# Calls adopt for $uid, the uid of the backup or undef if the restore does not adopt one, as the
# last step of a restore, and logs the result. A failure only warns, as the guest itself got
# restored and keeps the identity of its reservation.
sub adopt_from_backup($class, $vmid, $uid, $reservation) {
    my $res = eval { adopt($class, $vmid, $uid, $reservation) };
    if (my $err = $@) {
        chomp($err);
        my $kept = $reservation->{assigned}->{uid} // 'none';
        my $msg =
            defined($uid)
            ? "unable to adopt backup uid $uid, keeping uid $kept"
            : "keeping uid $kept";
        PVE::RESTEnvironment::log_warn("guest identity: $msg - $err");
        return;
    }

    print adopt_result_message($res, 'backup') . "\n";

    return;
}

PVE::JSONSchema::register_standard_option(
    'pve-guest-allow-new-uid',
    {
        type => 'boolean',
        description => "Allow the migration if another guest in the target cluster already has the"
            . " uid of this guest. The migrated guest then gets a new uid.",
        optional => 1,
        default => 0,
    },
);

# Returns the properties of the parameters of the 'identity' command of the migration tunnel, see
# handle_tunnel_identity. Every call returns a new copy.
sub tunnel_identity_cmd_schema() {
    return {
        uid => {
            type => 'string',
            description => 'uid of the source guest',
        },
        'allow-new-uid' => PVE::JSONSchema::get_standard_option('pve-guest-allow-new-uid'),
    };
}

# Handles the 'identity' command with the parameters $params on the target of a remote migration of
# a guest of the config class $class: adopts the uid of the source guest for the guest that the
# tunnel reserved with $reservation, logs the result, and returns the reply for the source. $state
# is the state of the tunnel, with the VMID in 'vmid' and the lock of the guest in 'lock'.
#
# The command is only accepted once, and only before the config arrives, while the guest still has
# the 'create' lock of the reservation. If another guest in the cluster has the uid, the command
# fails, which refuses the migration, unless the parameter 'allow-new-uid' is set, in which case the
# guest keeps the uid of its reservation.
sub handle_tunnel_identity($class, $state, $reservation, $params) {
    die "the uid can only be adopted once, before the config arrives\n"
        if ($state->{lock} // '') ne 'create' || $state->{'identity-handled'};
    $state->{'identity-handled'} = 1;

    my $uid = $params->{uid};
    my $res = eval { adopt($class, $state->{vmid}, $uid, $reservation) };
    die "unable to adopt the uid of the source guest - $@" if $@;

    if ($res->{result} eq 'in-use' && !$params->{'allow-new-uid'}) {
        die "guest $res->{'in-use-by'} in the target cluster already has the uid '$uid' of this"
            . " guest - use 'allow-new-uid' to migrate it with a new uid\n";
    }

    print adopt_result_message($res, 'source guest') . "\n";

    return { identity => $res };
}

# For the 'config' command on the target of a remote migration, with the state $state of the
# tunnel and the reservation $reservation of the guest: logs that the guest got a new uid if the
# source did not send the 'identity' command. Only a source without guest identities sends no
# 'identity' command, and a migration back to such a cluster gets refused.
sub log_tunnel_identity_not_sent($state, $reservation) {
    return if $state->{'identity-handled'};

    my $uid = $reservation->{assigned}->{uid};
    print "guest identity: the source sent no uid, the migrated guest has the new uid $uid\n";
    print "guest identity: the source cluster does not support guest identities yet, so a"
        . " migration back there gets refused\n";

    return;
}

# Returns undef if $node runs a version of Proxmox VE that keeps the identity when writing guest
# configs, see MIN_PVE_MANAGER_VERSION, or if it reports no version. Otherwise returns a hash with
# 'required-version', the minimum version, and 'version', the version the node reports.
sub node_identity_unsupported($node) {
    my $required = MIN_PVE_MANAGER_VERSION;
    my ($major, $minor, $release) = split(/\./, $required);

    my $supported =
        eval { PVE::Cluster::node_pvecfg_version_at_least($node, $major, $minor, $release) };
    return undef if $supported;

    # Every node reports its version since Proxmox VE 7.1. A missing one has not arrived yet, for
    # example right after the node joined the cluster, so it is no reason to refuse the node.
    my $version = eval { PVE::Cluster::get_node_pvecfg_version($node) };
    return undef if !defined($version);

    return { 'required-version' => $required, version => $version };
}

# Returns the JSON schema of what node_identity_unsupported returns for a refused node, for the
# result of API calls that report why a node is not allowed as migration target. Every call returns
# a new copy.
sub node_identity_unsupported_schema() {
    return {
        description =>
            "Set if migrating to the node is refused because the node runs a Proxmox VE"
            . " version that does not keep the guest identity.",
        type => 'object',
        optional => 1,
        properties => {
            version => {
                description => "The Proxmox VE version the node reports.",
                type => 'string',
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

    die "node '$node' runs Proxmox VE $version, keeping the guest identity requires $required or"
        . " newer - upgrade the node first\n";
}

1;
