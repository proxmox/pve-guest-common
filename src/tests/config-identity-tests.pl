#!/usr/bin/perl

use v5.36;

use lib qw(..);

use File::Temp qw(tempdir);
use Storable qw(dclone);
use Test::MockModule;
use Test::More;

use PVE::AbstractConfig;
use PVE::GuestIdentity;

my $tmpdir = tempdir('config-identity-XXXXXX', DIR => '.', CLEANUP => 1);

# guest config classes using a minimal config file format, see below

package PVE::TestConfig {
    use base qw(PVE::AbstractConfig);

    sub guest_type { return 'VM'; }

    sub config_file_lock($class, $vmid) {
        return "$tmpdir/config-$vmid.lock";
    }

    sub cfs_config_path($class, $vmid, $node = undef) {
        return "nodes/local/qemu-server/$vmid.conf";
    }

    # keeps any direct file access of the config class out of /etc/pve
    sub config_file($class, $vmid, $node = undef) {
        return "$tmpdir/etc-pve/" . $class->cfs_config_path($vmid, $node);
    }

    sub __identity_enabled { return 1; }

    # just enough for snapshot rollbacks without volumes
    sub valid_volume_keys { return (); }
    sub __snapshot_check_running { return 0; }
    sub __snapshot_rollback_vm_stop { return; }
    sub __snapshot_rollback_get_unused { return []; }
}

package PVE::TestConfig::CT {
    use base qw(PVE::TestConfig);

    sub guest_type { return 'CT'; }

    sub cfs_config_path($class, $vmid, $node = undef) {
        return "nodes/local/lxc/$vmid.conf";
    }
}

package PVE::TestConfig::NoIdentity {
    use base qw(PVE::TestConfig);

    sub __identity_enabled { return 0; }
}

package main;

# fake cluster filesystem with raw config files, indexed by their cfs path, and a file cache that
# behaves like the one of PVE::Cluster: it only reads a config again after a write of this process,
# or after cfs_update noticed a newer version

my $files = {};
my $versions = {};
my $version_counter = 0;
my $seen_versions = {};
my $cache = {};

our $get_config_error;

my $reads = 0;
my $writes = 0;

sub parse_test_config($raw) {
    my $conf = { snapshots => {} };
    my $section = $conf;
    for my $line (split(/\n/, $raw)) {
        next if $line =~ m/^\s*$/;
        if ($line =~ m/^\[([^\]]+)\]$/) {
            $section = $conf->{snapshots}->{$1} = {};
        } elsif ($line =~ m/^([a-z][a-z0-9_\-]*):\s*(.*?)\s*$/) {
            $section->{$1} = $2;
        } else {
            die "test error: unable to parse config line '$line'\n";
        }
    }

    return $conf;
}

sub write_test_config($conf) {
    my $print_section = sub {
        my ($section) = @_;
        return join('',
            map { "$_: $section->{$_}\n" } grep { !ref($section->{$_}) } sort keys %$section);
    };

    my $raw = $print_section->($conf);
    for my $snapname (sort keys(($conf->{snapshots} // {})->%*)) {
        $raw .= "\n[$snapname]\n" . $print_section->($conf->{snapshots}->{$snapname});
    }

    return $raw;
}

sub vmid_of_path($path) {
    return $path =~ m!/(\d+)\.conf$! ? $1 : die "test error: unexpected path '$path'\n";
}

my $cluster_module = Test::MockModule->new('PVE::Cluster');
$cluster_module->redefine(
    cfs_update => sub {
        $seen_versions = { $versions->%* };
        return;
    },
    cfs_read_file => sub {
        my ($path) = @_;
        my $version = $seen_versions->{$path};
        my $entry = $cache->{$path};
        if (!$entry || !$entry->{version} || !$version || $entry->{version} != $version) {
            my $raw = $files->{$path};
            my $data = defined($raw) ? parse_test_config($raw) : undef;
            $entry = $cache->{$path} = { version => $version, data => $data };
        }
        return defined($entry->{data}) ? dclone($entry->{data}) : undef;
    },
    cfs_write_file => sub {
        my ($path, $conf) = @_;
        $writes++;
        $files->{$path} = write_test_config($conf);
        $versions->{$path} = ++$version_counter;
        $cache->{$path}->{version} = undef if $cache->{$path};
    },
    get_config => sub {
        my ($path) = @_;
        die $get_config_error if $get_config_error;
        $reads++;
        return $files->{$path};
    },
);

# deterministic identities: uids count up, the time is set by the tests

my $uid_counter = 0;
my $now = 1_700_000_000_000;

# recording used guest IDs needs the cluster filesystem and is not what gets tested here
my $guest_id_module = Test::MockModule->new('PVE::GuestID');
$guest_id_module->redefine(register_used_id => sub { });

my $identity_module = Test::MockModule->new('PVE::GuestIdentity');
$identity_module->redefine(
    # one byte per uid character, the last three count up
    __random_bytes => sub {
        my ($len) = @_;
        my $n = ++$uid_counter;
        return ("\0" x ($len - 3)) . pack('C3', map { ($n >> $_) & 31 } (10, 5, 0));
    },
    __time_ms => sub { return $now; },
);

my sub new_uid {
    return PVE::GuestIdentity::new_identity()->{uid};
}

my sub file_of($class, $vmid) {
    return $files->{ $class->cfs_config_path($vmid) };
}

my sub conf_of($class, $vmid) {
    my $raw = file_of($class, $vmid);
    return defined($raw) ? parse_test_config($raw) : undef;
}

my sub identity_of($class, $vmid) {
    my $conf = conf_of($class, $vmid) or return undef;
    return PVE::GuestIdentity::parse_identity($conf->{meta});
}

# write of another process, the file cache of this process does not notice it
my sub set_file($class, $vmid, $raw) {
    my $path = $class->cfs_config_path($vmid);
    $files->{$path} = $raw;
    $versions->{$path} = ++$version_counter;
}

my $foreign_uid = new_uid();

subtest 'disabled by default' => sub {
    ok(!PVE::AbstractConfig->__identity_enabled(), 'abstract config does not enable it');

    my $class = 'PVE::TestConfig::NoIdentity';
    my $reads_before = $reads;

    my $res = [$class->write_config(100, { name => 'a' })];
    is(file_of($class, 100), "name: a\n", 'config without identity written as is');
    is_deeply($res, [], 'nothing is returned');

    my $meta = "ctime=1,rtime=5,uid=$foreign_uid";
    $class->write_config(100, { name => 'a', meta => $meta });
    is(file_of($class, 100), "meta: $meta\nname: a\n", 'carried identity written as is');

    is($reads, $reads_before, 'stored identity is not read');
};

subtest 'none stored' => sub {
    my $class = 'PVE::TestConfig';

    my $conf = { name => 'new' };
    my $res = [$class->write_config(101, $conf)];
    my $identity = identity_of($class, 101);
    ok($identity, 'new config gets an identity');
    is($identity->{rtime}, $now, 'rtime is the current time');
    is_deeply($class->get_identity($conf), $identity, 'identity is set in the written hash');
    is_deeply($res, [], 'nothing is returned');

    # copied from a clone source, a snapshot, or a backup
    $class->write_config(102, { name => 'clone', meta => "ctime=7,rtime=5,uid=$foreign_uid" });
    $identity = identity_of($class, 102);
    isnt($identity->{uid}, $foreign_uid, 'carried identity is not stored');
    is($identity->{rtime}, $now, 'carried rtime is not stored');
    like(
        file_of($class, 102),
        qr/^meta: ctime=7,rtime=$now,uid=[a-z2-7]{20}$/m,
        'other members are kept',
    );

    set_file($class, 103, "meta: ctime=1\nname: old\n");
    $class->write_config(103, conf_of($class, 103));
    $identity = identity_of($class, 103);
    ok($identity, 'existing config without identity gets one');
    like(file_of($class, 103), qr/^meta: ctime=1,rtime=$now,uid=/m, 'other members are kept');

    set_file($class, 104, "name: old\n\n[snap]\nmeta: rtime=1,uid=$foreign_uid\n");
    $class->write_config(104, conf_of($class, 104));
    isnt(identity_of($class, 104)->{uid}, $foreign_uid, 'identity of a snapshot is ignored');
    like(
        file_of($class, 104),
        qr/^\[snap\]\nmeta: rtime=1,uid=$foreign_uid$/m,
        'snapshot keeps its copy',
    );

    set_file($class, 105, '');
    $class->write_config(105, { name => 'empty' });
    ok(identity_of($class, 105), 'existing empty config gets an identity');
};

subtest 'stored identity wins' => sub {
    my $class = 'PVE::TestConfig';

    $class->write_config(110, { name => 'a', meta => 'ctime=1' });
    my $stored = identity_of($class, 110);
    my $stale = new_uid();

    $now += 1000;

    my $tests = [
        [{ name => 'b' }, 'missing identity'],
        [{ name => 'b', meta => 'ctime=1' }, 'missing identity members'],
        [{ name => 'b', meta => "ctime=1,rtime=5,uid=$stale" }, 'stale identity'],
        [{ name => 'b', meta => "ctime=1,rtime=$now,uid=$foreign_uid" }, 'foreign identity'],
        [{ name => 'b', meta => "ctime=1,rtime=5,uid=bogus" }, 'invalid identity'],
        [{ name => 'b', meta => "ctime=1,uid=$stored->{uid}" }, 'identity without rtime'],
    ];

    for my $test (@$tests) {
        my ($conf, $name) = @$test;
        my $other_members = $conf->{meta} && $conf->{meta} =~ m/ctime=1/;

        $class->write_config(110, $conf);
        is_deeply(identity_of($class, 110), $stored, "$name: stored identity is kept");
        is_deeply($class->get_identity($conf), $stored, "$name: hash has it too");
        like(file_of($class, 110), qr/^meta: ctime=1,/m, "$name: other members are kept")
            if $other_members;
    }

    set_file($class, 111, "meta: ctime=1,uid=$stale\nname: old\n");
    $class->write_config(111, conf_of($class, 111));
    is_deeply(
        identity_of($class, 111),
        { uid => $stale, rtime => $now },
        'stored uid without rtime is kept and gets the current time',
    );

    my ($first, $last) = (new_uid(), new_uid());
    set_file($class, 112, "meta: rtime=1,uid=$first\nname: x\nmeta: rtime=2,uid=$last\n");
    $class->write_config(112, { name => 'y' });
    is_deeply(
        identity_of($class, 112),
        { uid => $last, rtime => 2 },
        'last top-level meta line counts, like for the config parsers',
    );
};

subtest 'read errors are fatal' => sub {
    my $class = 'PVE::TestConfig';

    $class->write_config(130, { name => 'a' });
    my $raw = file_of($class, 130);

    {
        local $get_config_error = "Connection refused\n";
        eval { $class->write_config(130, { name => 'b' }) };
        is($@, "Connection refused\n", 'write dies');
        is(file_of($class, 130), $raw, 'config is unchanged');

        eval { $class->write_config(131, { name => 'b' }) };
        is($@, "Connection refused\n", 'write of new config dies');
        ok(!defined(file_of($class, 131)), 'config is not written');
    }
};

subtest 'snapshot rollback' => sub {
    my $class = 'PVE::TestConfig';

    my $storage_module = Test::MockModule->new('PVE::Storage');
    $storage_module->redefine(config => sub { return {}; });
    my $replication_module = Test::MockModule->new('PVE::ReplicationConfig');
    $replication_module->redefine(
        new => sub { return bless({}, 'PVE::ReplicationConfig'); },
        check_for_existing_jobs => sub { return 0; },
    );

    $class->write_config(140, { name => 'current', meta => 'ctime=2' });
    my $stored = identity_of($class, 140);

    my $conf = conf_of($class, 140);
    $conf->{snapshots}->{old} = { name => 'old', meta => "ctime=1,rtime=5,uid=$foreign_uid" };
    $conf->{snapshots}->{none} = { name => 'none' };
    $class->write_config(140, $conf);

    $now += 1000;

    for my $snapname (qw(old none)) {
        $class->snapshot_rollback(140, $snapname);
        $conf = conf_of($class, 140);
        is($conf->{name}, $snapname, "rolled back to '$snapname'");
        is_deeply(identity_of($class, 140), $stored, "'$snapname': current identity is kept");
    }
    is(
        $conf->{snapshots}->{old}->{meta},
        "ctime=1,rtime=5,uid=$foreign_uid",
        'snapshot is unchanged',
    );
};

done_testing();
