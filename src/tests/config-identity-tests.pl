#!/usr/bin/perl

use v5.36;

use lib qw(..);

use File::Temp qw(tempdir);
use Storable qw(dclone);
use Test::MockModule;
use Test::More;

use PVE::AbstractConfig;
use PVE::AbstractMigrate;
use PVE::GuestIdentity;
use PVE::JSONSchema;

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
our $lock_domain_error;
our $domain_locked = 0;
our $on_lookup;

my $reads = 0;
my $writes = 0;
my $domain_writes = 0;

sub parse_test_config($raw) {
    my $conf = { snapshots => {} };
    my $section = $conf;
    for my $line (split(/\n/, $raw)) {
        next if $line =~ m/^\s*$/;
        if ($line =~ m/^\[PENDING\]$/) {
            $section = $conf->{pending} = {};
        } elsif ($line =~ m/^\[([^\]]+)\]$/) {
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
    $raw .= "\n[PENDING]\n" . $print_section->($conf->{pending})
        if scalar(keys(($conf->{pending} // {})->%*));
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
        $domain_writes++ if $domain_locked;
        $files->{$path} = write_test_config($conf);
        $versions->{$path} = ++$version_counter;
        $cache->{$path}->{version} = undef if $cache->{$path};
    },
    check_vmid_unused => sub {
        my ($vmid, $noerr) = @_;
        return 1 if !grep { defined($files->{$_}) && vmid_of_path($_) == $vmid } keys %$files;
        return undef if $noerr;
        die "guest $vmid already exists\n";
    },
    get_guest_config_properties => sub {
        my ($properties, $vmid) = @_;
        die "test error: unexpected arguments\n" if defined($vmid) || "@$properties" ne 'meta';

        my $res = {};
        for my $path (grep { defined($files->{$_}) } keys %$files) {
            for my $line (split(/\n/, $files->{$path})) {
                last if $line =~ m/^\[/;
                # like pmxcfs, a line with nothing after the colon does not count
                $res->{ vmid_of_path($path) }->{meta} = $1 =~ s/^\s+|\s+$//gr
                    if $line =~ m/^meta:(.+)$/;
            }
        }

        $on_lookup->() if $on_lookup;

        return $res;
    },
    cfs_lock_domain => sub {
        my ($domain, $timeout, $code, @param) = @_;
        die "test error: unexpected lock domain '$domain'\n" if $domain ne 'guest-identity';
        die "test error: nested domain lock\n" if $domain_locked;

        if ($lock_domain_error) {
            $@ = $lock_domain_error;
            return undef;
        }

        local $domain_locked = 1;
        PVE::Cluster::cfs_update();
        # like the real one, errors of $code are passed on in $@
        return eval { $code->(@param) };
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

# recording used guest IDs needs the cluster filesystem, only one subtest fakes the list of them
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

subtest 'stored identity check' => sub {
    my $class = 'PVE::TestConfig';

    ok(!$class->has_stored_identity(106), 'missing config has none');

    set_file($class, 106, "meta: ctime=1\nname: old\n");
    ok(!$class->has_stored_identity(106), 'config without identity has none');

    set_file($class, 106, "meta: ctime=1,rtime=5,uid=$foreign_uid,zz-future=x\nname: old\n");
    ok($class->has_stored_identity(106), 'identity next to members unknown to this version');

    set_file($class, 106, "name: old\n\n[snap]\nmeta: rtime=1,uid=$foreign_uid\n");
    ok(!$class->has_stored_identity(106), 'identity of a snapshot does not count');
};

subtest 'none assigned under the migrate lock' => sub {
    my $class = 'PVE::TestConfig';

    set_file($class, 120, "meta: creation-qemu=10.1.0,ctime=1\nname: old\n");
    my $conf = conf_of($class, 120);
    $conf->{lock} = 'migrate';
    $class->write_config(120, $conf);
    ok(!identity_of($class, 120), 'config without identity gets none');
    like(
        file_of($class, 120),
        qr/^lock: migrate\nmeta: creation-qemu=10\.1\.0,ctime=1\n/m,
        'meta is written without identity members',
    );

    # copied from elsewhere, but not stored
    $conf->{meta} = "creation-qemu=10.1.0,ctime=1,rtime=5,uid=$foreign_uid";
    $class->write_config(120, $conf);
    ok(!identity_of($class, 120), 'carried identity is not written');
    like(file_of($class, 120), qr/^meta: creation-qemu=10\.1\.0,ctime=1$/m, 'members are kept');

    $conf->{meta} = "rtime=5,uid=$foreign_uid";
    $class->write_config(120, $conf);
    ok(!defined($conf->{meta}), 'meta with only identity members is removed');
    unlike(file_of($class, 120), qr/^meta:/m, 'and not written');

    delete $conf->{lock};
    $class->write_config(120, $conf);
    my $identity = identity_of($class, 120);
    ok($identity, 'removing the lock assigns an identity');
    isnt($identity->{uid}, $foreign_uid, 'not the carried one');

    # also if the parser of the guest type dropped 'meta'
    $conf->{lock} = 'migrate';
    delete $conf->{meta};
    $class->write_config(120, $conf);
    is_deeply(identity_of($class, 120), $identity, 'a stored identity is kept under the lock');

    set_file($class, 121, "name: other\n");
    $conf = conf_of($class, 121);
    $conf->{lock} = 'backup';
    $class->write_config(121, $conf);
    ok(identity_of($class, 121), 'other locks do not keep the guest without identity');
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

subtest 'create and lock config' => sub {
    my $class = 'PVE::TestConfig';

    my $state = $class->create_and_lock_config(150);
    my $reserved = identity_of($class, 150);
    ok($reserved, 'free VMID: reservation gets an identity');
    is_deeply(
        $state,
        {
            existed => 0,
            previous => undef,
            'previous-pending-uid' => undef,
            assigned => $reserved,
        },
        'free VMID: no previous identity',
    );
    is(conf_of($class, 150)->{lock}, 'create', 'free VMID: reserved');

    eval { $class->create_and_lock_config(150) };
    like($@, qr/already exists/, 'existing config is refused by default');

    $class->write_config(151, { name => 'target', meta => 'ctime=1' });
    my $stored = identity_of($class, 151);
    $now += 1000;
    $state = $class->create_and_lock_config(151, 1, 'restore');
    is_deeply(
        $state,
        {
            existed => 1,
            previous => $stored,
            'previous-pending-uid' => undef,
            assigned => $stored,
        },
        'in place: previous identity',
    );
    my $conf = conf_of($class, 151);
    is($conf->{lock}, 'restore', 'in place: locked');
    is($conf->{name}, 'target', 'in place: config is kept');
    is_deeply(identity_of($class, 151), $stored, 'in place: identity is kept');

    eval { $class->create_and_lock_config(151, 1) };
    like($@, qr/^VM is locked \(restore\)/, 'locked config is refused');

    eval { $class->create_and_lock_config(159, 'require') };
    like($@, qr/^Configuration file '.*' does not exist/,
        'required config is missing: refused');
    ok(!defined(file_of($class, 159)), 'required config is missing: nothing is written');

    set_file($class, 152, "meta: ctime=1\nname: old\n");
    $state = $class->create_and_lock_config(152, 1);
    is_deeply(
        $state,
        {
            existed => 1,
            previous => undef,
            'previous-pending-uid' => undef,
            assigned => identity_of($class, 152),
        },
        'in place without identity: reservation gets one',
    );
    ok($state->{assigned}, 'in place without identity: reserved identity');

    set_file($class, 157, '');
    $state = $class->create_and_lock_config(157, 1);
    is_deeply(
        $state,
        {
            existed => 1,
            previous => undef,
            'previous-pending-uid' => undef,
            assigned => identity_of($class, 157),
        },
        'in place with empty config: reservation gets an identity',
    );
    ok($state->{assigned}, 'in place with empty config: reserved identity');

    my $unloadable = "lock: backup\nmeta: rtime=5,uid=$foreign_uid\nname: old\n!unparsable\n";
    set_file($class, 156, $unloadable);
    eval { $class->create_and_lock_config(156, 1) };
    like($@, qr/^test error: unable to parse/, 'in place, config fails to load: refused');
    is(file_of($class, 156), $unloadable, 'in place, config fails to load: file is unchanged');

    # the guest list of the process can predate a config created since
    my $check_vmid_unused = PVE::Cluster->can('check_vmid_unused');
    $cluster_module->redefine(check_vmid_unused => sub { return 1; });
    for my $raw ("name: other\n", $unloadable) {
        set_file($class, 158, $raw);
        eval { $class->create_and_lock_config(158) };
        is($@, "VM 158 already exists\n", 'outdated guest list: existing config is refused');
        is(file_of($class, 158), $raw, 'outdated guest list: file is unchanged');
    }
    $cluster_module->redefine(check_vmid_unused => $check_vmid_unused);

    # clone: the target's first write must not store the source's identity
    $state = $class->create_and_lock_config(153);
    $conf = conf_of($class, 151);
    delete $conf->{lock};
    $class->write_config(153, $conf);
    is_deeply(identity_of($class, 153), $state->{assigned},
        'clone keeps the reserved identity');
    like(file_of($class, 153), qr/^meta: ctime=1,/m, 'clone keeps other members of the source');

    $class = 'PVE::TestConfig::NoIdentity';

    $state = $class->create_and_lock_config(154);
    is_deeply(
        $state,
        { existed => 0, previous => undef, 'previous-pending-uid' => undef, assigned => undef },
        'disabled, free VMID: no previous identity',
    );
    is(file_of($class, 154), "lock: create\n", 'disabled, free VMID: no identity assigned');

    set_file($class, 155, "meta: ctime=1,rtime=5,uid=$foreign_uid\nname: old\n");
    $state = $class->create_and_lock_config(155, 1);
    is_deeply(
        $state,
        {
            existed => 1,
            previous => { uid => $foreign_uid, rtime => 5 },
            'previous-pending-uid' => undef,
            assigned => undef,
        },
        'disabled, in place: identity from the config',
    );
    is(
        file_of($class, 155),
        "lock: create\nmeta: ctime=1,rtime=5,uid=$foreign_uid\nname: old\n",
        'disabled, in place: config is kept',
    );
};

subtest 'create and lock config with unique and enforced guest IDs' => sub {
    my $class = 'PVE::TestConfig';

    # PVE::GuestID imported the functions it uses to access its files, so fake them there, with the
    # parser and writer it registered for the list of used guest IDs
    my (undef, $id_list) = PVE::Cluster::cfs_file_version('virtual-guest/used-guest-ids');
    my $used_ids = "500\n";
    my $dc_conf = { 'next-id' => { unique => 1, enforce => 1 } };
    $guest_id_module->unmock('register_used_id');
    $guest_id_module->redefine(
        cfs_read_file => sub($filename) {
            return $dc_conf if $filename eq 'datacenter.cfg';
            die "test error: unexpected read of '$filename'\n"
                if $filename ne 'virtual-guest/used-guest-ids';
            return $id_list->{parser}->("/etc/pve/$filename", $used_ids);
        },
        cfs_write_file => sub($filename, $ranges) {
            $used_ids = $id_list->{writer}->("/etc/pve/$filename", $ranges);
        },
        cfs_lock_file => sub($filename, $timeout, $code) {
            return eval { $code->() };
        },
    );

    eval { $class->create_and_lock_config(500) };
    is($@, "guest ID 500 was used before\n", 'used VMID is refused');
    ok(!defined(file_of($class, 500)), 'refused VMID: no config is left behind');

    my $created = $class->create_and_lock_config(510);
    $class->write_config(510, { name => 'existing' });
    my $state = $class->create_and_lock_config(510, 1, 'restore');
    is_deeply(
        $state,
        {
            existed => 1,
            previous => $created->{assigned},
            'previous-pending-uid' => undef,
            assigned => $created->{assigned},
        },
        'existing guest: reservation is accepted and returns its identity',
    );
    is(conf_of($class, 510)->{lock}, 'restore', 'existing guest: locked');

    $class->create_and_lock_config(520);
    is($used_ids, "500\n510\n520\n", 'new reservations are recorded as used');

    # like a failed restore that releases the VMID it reserved
    my $path = $class->cfs_config_path(520);
    delete $files->{$path};
    $versions->{$path} = ++$version_counter;

    for my $force (0, 1) {
        eval { $class->create_and_lock_config(520, $force) };
        is($@, "guest ID 520 was used before\n", "released VMID is refused (force: $force)");
    }
    ok(!defined(file_of($class, 520)), 'released VMID: no config is left behind');

    $guest_id_module->unmock(qw(cfs_read_file cfs_write_file cfs_lock_file));
    $guest_id_module->redefine(register_used_id => sub { });
};

subtest 'adopt' => sub {
    my $class = 'PVE::TestConfig';
    my $ct_class = 'PVE::TestConfig::CT';

    my $backup_uid = new_uid();

    # restore to a free VMID, the final write carries the identity of the backup
    my $reservation = $class->create_and_lock_config(200);
    my $restored = { name => 'restored', meta => "ctime=1,rtime=5,uid=$backup_uid" };
    $class->write_config(200, { $restored->%*, lock => 'create' });
    my $generated = identity_of($class, 200);
    is_deeply($generated, $reservation->{assigned}, 'final write keeps the reserved identity');

    $now += 1000;
    my $res = PVE::GuestIdentity::adopt($class, 200, $backup_uid, $reservation);
    is_deeply(
        $res,
        { result => 'adopted', uid => $backup_uid, requested => $backup_uid },
        'free uid is adopted',
    );
    is_deeply(
        identity_of($class, 200),
        { uid => $backup_uid, rtime => $now },
        'adopted uid is stored with the current time',
    );
    like(
        file_of($class, 200),
        qr/^meta: ctime=1,rtime=$now,uid=$backup_uid$/m,
        'other members are kept',
    );
    is(conf_of($class, 200)->{lock}, 'create', 'rest of the config is kept');
    is($domain_writes, 1, 'stored under the cluster-wide lock');

    my $adopted_rtime = $now;
    $now += 1000;

    my $stale = { $restored->%*, meta => "ctime=1,rtime=5,uid=$generated->{uid}" };
    $class->write_config(200, $stale);
    is_deeply(
        identity_of($class, 200),
        { uid => $backup_uid, rtime => $adopted_rtime },
        'later write of a stale hash keeps the adopted identity',
    );

    my $writes_before = $writes;
    $res = PVE::GuestIdentity::adopt($class, 200, $backup_uid, $reservation);
    is_deeply(
        $res,
        { result => 'kept', uid => $backup_uid, requested => $backup_uid },
        'repeated adoption keeps it',
    );
    is($writes, $writes_before, 'repeated adoption writes nothing');
    is(identity_of($class, 200)->{rtime}, $adopted_rtime, 'repeated adoption keeps rtime');

    # restore in place onto a guest with identity
    $class->write_config(210, { name => 'target' });
    my $target = identity_of($class, 210);
    $reservation = $class->create_and_lock_config(210, 1, 'restore');
    my $other_uid = new_uid();
    {
        local $lock_domain_error = "test error: unexpected lock\n";
        $res = PVE::GuestIdentity::adopt($class, 210, $other_uid, $reservation);
    }
    is_deeply(
        $res,
        { result => 'kept', uid => $target->{uid}, requested => $other_uid },
        'in place: identity from before the operation is kept',
    );
    is_deeply(identity_of($class, 210), $target, 'in place: identity is unchanged');

    set_file($class, 211, "meta: ctime=1\nname: old\n");
    $reservation = $class->create_and_lock_config(211, 1);
    $other_uid = new_uid();
    $res = PVE::GuestIdentity::adopt($class, 211, $other_uid, $reservation);
    is($res->{result}, 'adopted', 'in place without identity: uid is adopted');
    is(identity_of($class, 211)->{uid}, $other_uid, 'in place without identity: stored');

    $reservation = $class->create_and_lock_config(212);
    {
        local $lock_domain_error = "test error: unexpected lock\n";
        $res = PVE::GuestIdentity::adopt($class, 212, undef, $reservation);
    }
    is_deeply(
        $res,
        { result => 'skipped', uid => $reservation->{assigned}->{uid}, requested => undef },
        'nothing to adopt',
    );

    $reservation = $class->create_and_lock_config(201);
    $class->write_config(201, { name => 'second restore', lock => 'create' });
    my $second = identity_of($class, 201);
    $writes_before = $writes;
    $res = PVE::GuestIdentity::adopt($class, 201, $backup_uid, $reservation);
    is_deeply(
        $res,
        {
            result => 'in-use',
            uid => $second->{uid},
            requested => $backup_uid,
            'in-use-by' => 200,
        },
        'uid of another VM is not adopted',
    );
    is_deeply(identity_of($class, 201), $second, 'reserved identity stays');
    is($writes, $writes_before, 'nothing is written');

    # manual copies of a config
    my $copied_uid = new_uid();
    set_file($class, 220, "meta: rtime=1,uid=$copied_uid\n");
    set_file($ct_class, 205, "meta: rtime=1,uid=$copied_uid\n");
    $res = PVE::GuestIdentity::adopt($class, 201, $copied_uid, $reservation);
    is($res->{'in-use-by'}, 205, 'lowest VMID of several holders is reported');

    my $hidden_uid = new_uid();
    set_file($class, 221, "meta: rtime=1,uid=$hidden_uid\nmeta:\n");
    $res = PVE::GuestIdentity::adopt($class, 201, $hidden_uid, $reservation);
    is($res->{'in-use-by'}, 221, 'meta line without value does not hide the uid before it');

    my $ct_uid = new_uid();
    my $ct_reservation = $ct_class->create_and_lock_config(300);
    $res = PVE::GuestIdentity::adopt($ct_class, 300, $ct_uid, $ct_reservation);
    is($res->{result}, 'adopted', 'container adopts a free uid');
    like(file_of($ct_class, 300), qr/^meta: rtime=$now,uid=$ct_uid$/m, 'container config');

    $res = PVE::GuestIdentity::adopt($class, 201, $ct_uid, $reservation);
    is($res->{'in-use-by'}, 300, 'uid of a container is not adopted for a VM');

    $ct_reservation = $ct_class->create_and_lock_config(301);
    $res = PVE::GuestIdentity::adopt($ct_class, 301, $backup_uid, $ct_reservation);
    is($res->{'in-use-by'}, 200, 'uid of a VM is not adopted for a container');

    # another process writes the config after the cluster-wide lookup
    $reservation = $class->create_and_lock_config(230);
    $class->write_config(230, { name => 'restored', lock => 'create' });
    PVE::Cluster::cfs_update();
    $class->load_config(230);
    {
        local $on_lookup = sub {
            set_file($class, 230, file_of($class, 230) =~ s/^name: .*$/name: hook/mr);
        };
        $res = PVE::GuestIdentity::adopt($class, 230, new_uid(), $reservation);
    }
    is($res->{result}, 'adopted', 'concurrent write: uid is adopted');
    is(conf_of($class, 230)->{name}, 'hook', 'concurrent write: its change is kept');

    $reservation = $class->create_and_lock_config(202);
    my $before = identity_of($class, 202);
    {
        local $lock_domain_error = "cfs-lock 'domain-guest-identity' error: no quorum!\n";
        eval { PVE::GuestIdentity::adopt($class, 202, new_uid(), $reservation) };
        is($@, $lock_domain_error, 'lock error is passed on');
        is_deeply(identity_of($class, 202), $before, 'lock error: identity is unchanged');
    }

    my $missing =
        { existed => 0, previous => undef, assigned => PVE::GuestIdentity::new_identity() };
    eval { PVE::GuestIdentity::adopt($class, 299, new_uid(), $missing) };
    like($@, qr/does not exist/, 'missing config is an error');

    eval { PVE::GuestIdentity::adopt($class, 202, 'GAYTEMZUGU3DOOBZMFRG', $reservation) };
    like($@, qr/invalid guest identity uid/, 'invalid uid is refused');

    for my $invalid (undef, {}, { existed => 0, previous => undef, assigned => undef }) {
        eval { PVE::GuestIdentity::adopt($class, 202, new_uid(), $invalid) };
        like($@, qr/missing guest identity reservation/, 'missing reservation is refused');
    }

    eval {
        PVE::GuestIdentity::adopt('PVE::TestConfig::NoIdentity', 202, new_uid(), $reservation);
    };
    like($@, qr/not enabled/, 'guest type without identities is refused');
};

subtest 'adopt from backup' => sub {
    my $class = 'PVE::TestConfig';

    my $warnings = [];
    my $restenv_module = Test::MockModule->new('PVE::RESTEnvironment');
    $restenv_module->redefine(log_warn => sub($msg) { push $warnings->@*, $msg; });

    my $adopt_from_backup = sub($vmid, $uid, $reservation) {
        my $output = '';
        open(my $fh, '>', \$output) or die "unable to capture output - $!\n";
        my $previous_fh = select($fh);
        eval { PVE::GuestIdentity::adopt_from_backup($class, $vmid, $uid, $reservation) };
        my $err = $@;
        select($previous_fh);
        close($fh);
        die $err if $err;
        return $output;
    };

    my $backup_uid = new_uid();
    my $reservation = $class->create_and_lock_config(240);
    is(
        $adopt_from_backup->(240, $backup_uid, $reservation),
        "guest identity: adopted uid $backup_uid from the backup\n",
        'result is logged',
    );
    is(identity_of($class, 240)->{uid}, $backup_uid, 'uid is adopted');

    $reservation = $class->create_and_lock_config(242);
    my $assigned_uid = $reservation->{assigned}->{uid};
    is(
        $adopt_from_backup->(242, $backup_uid, $reservation),
        "guest identity: backup uid $backup_uid is in use by guest 240, keeping uid"
            . " $assigned_uid\n",
        'uid in use: logged',
    );
    is(
        $adopt_from_backup->(242, undef, $reservation),
        "guest identity: new uid $assigned_uid\n",
        'nothing to adopt: logged',
    );

    $class->write_config(243, { name => 'target' });
    $reservation = $class->create_and_lock_config(243, 1);
    is(
        $adopt_from_backup->(243, new_uid(), $reservation),
        "guest identity: kept uid $reservation->{previous}->{uid}\n",
        'target with identity: logged',
    );

    $reservation = $class->create_and_lock_config(241);
    $assigned_uid = $reservation->{assigned}->{uid};
    $backup_uid = new_uid();
    $class->record_pending_uid(241, $backup_uid);
    {
        local $lock_domain_error = "cfs-lock 'domain-guest-identity' error: no quorum!\n";
        is($adopt_from_backup->(241, $backup_uid, $reservation), '', 'failure: no result');
    }
    is_deeply(
        $warnings,
        [
            "guest identity: unable to adopt backup uid $backup_uid, keeping uid $assigned_uid"
                . " - cfs-lock 'domain-guest-identity' error: no quorum!",
        ],
        'failure only warns',
    );

    $warnings = [];
    {
        local $get_config_error = "Connection refused\n";
        is($adopt_from_backup->(241, undef, $reservation), '', 'nothing to adopt, failure');
    }
    is_deeply(
        $warnings,
        [
            "guest identity: keeping uid $assigned_uid - unable to remove the pending uid -"
                . " Connection refused",
        ],
        'nothing to adopt, failure: warning without requested uid',
    );
};

# Returns the pending uid of a restore of a backup with the uid $uid over the guest $vmid, without
# 'allow-identity-mismatch'.
my sub prepare_restore($class, $vmid, $reservation, $uid) {
    return PVE::GuestIdentity::prepare_restore($class, $vmid, $reservation, $uid, 0);
}

# like the guest that a failed operation leaves behind, with the lock removed by its error handling
my sub unlock_config($class, $vmid) {
    my $conf = conf_of($class, $vmid);
    delete $conf->{lock};
    $class->write_config($vmid, $conf);
}

my sub pending_of($class, $vmid) {
    my $conf = conf_of($class, $vmid);
    return $conf->{pending} ? $conf->{pending}->{meta} : undef;
}

subtest 'pending uid' => sub {
    my $class = 'PVE::TestConfig';

    # a restore to a free VMID records the uid of the backup, then fails and leaves the guest
    my $backup_uid = new_uid();
    my $first = $class->create_and_lock_config(400);
    my $leftover = $first->{assigned};
    is(prepare_restore($class, 400, $first, $backup_uid), $backup_uid, 'free VMID: adoptable');
    is(pending_of($class, 400), "uid=$backup_uid", 'pending uid is recorded');
    is_deeply(identity_of($class, 400), $leftover, 'stored identity is kept');
    is(conf_of($class, 400)->{lock}, 'create', 'rest of the config is kept');
    unlock_config($class, 400);
    is(pending_of($class, 400), "uid=$backup_uid", 'write of the loaded config keeps it');

    # a retry at another VMID adopts the uid, as a pending uid is not in use
    my $elsewhere = $class->create_and_lock_config(401);
    my $res = PVE::GuestIdentity::adopt($class, 401, $backup_uid, $elsewhere);
    is($res->{result}, 'adopted',
        'retry elsewhere: pending uid of another guest is not in use');
    is(pending_of($class, 400), "uid=$backup_uid", 'retry elsewhere: leftover keeps it');

    # a retry over the leftover is a restore of the same backup, but the uid is in use by now
    my $retry = $class->create_and_lock_config(400, 1);
    is_deeply(
        $retry,
        {
            existed => 1,
            previous => $leftover,
            'previous-pending-uid' => $backup_uid,
            assigned => $leftover,
        },
        'reservation reports the pending uid',
    );
    my $writes_before = $writes;
    is(prepare_restore($class, 400, $retry, $backup_uid), $backup_uid,
        'pending uid: adoptable');
    is(prepare_restore($class, 400, $retry, $leftover->{uid}), undef, 'stored uid matches');
    eval { prepare_restore($class, 400, $retry, new_uid()) };
    like($@, qr/^backup belongs to another guest/, 'other uid does not match');
    is($writes, $writes_before, 'pending uid is not written again');
    $res = PVE::GuestIdentity::adopt($class, 400, $backup_uid, $retry);
    is_deeply(
        $res,
        {
            result => 'in-use',
            uid => $leftover->{uid},
            requested => $backup_uid,
            'in-use-by' => 401,
        },
        'retry in place after the retry elsewhere: in use',
    );
    is_deeply(identity_of($class, 400), $leftover, 'in use: identity is kept');
    ok(!defined(pending_of($class, 400)), 'in use: pending uid is removed');

    # a failed restore over a guest without identity, then retried in place
    set_file($class, 410, "name: old\n");
    $first = $class->create_and_lock_config(410, 1);
    $backup_uid = new_uid();
    is(prepare_restore($class, 410, $first, $backup_uid), $backup_uid,
        'no identity: adoptable');
    unlock_config($class, 410);

    $retry = $class->create_and_lock_config(410, 1);
    is($retry->{'previous-pending-uid'}, $backup_uid, 'retry in place: pending uid reported');
    $class->write_config(
        410,
        { name => 'restored', lock => 'create', pending => { meta => "uid=$backup_uid" } },
    );
    $now += 1000;
    $writes_before = $writes;
    $res = PVE::GuestIdentity::adopt($class, 410, $backup_uid, $retry);
    is_deeply(
        $res,
        { result => 'adopted', uid => $backup_uid, requested => $backup_uid },
        'retry in place: pending uid is adopted',
    );
    is_deeply(identity_of($class, 410), { uid => $backup_uid, rtime => $now }, 'stored');
    ok(!defined(pending_of($class, 410)), 'retry in place: pending uid is removed');
    is($writes, $writes_before + 1, 'in the same write');
    is(conf_of($class, 410)->{name}, 'restored', 'rest of the config is kept');

    # an in-place restore of another backup keeps the identity, with a pending uid of the earlier
    # backup
    set_file($class, 430, "name: old\n");
    $first = $class->create_and_lock_config(430, 1);
    my $earlier_uid = new_uid();
    $class->record_pending_uid(430, $earlier_uid);
    unlock_config($class, 430);
    $retry = $class->create_and_lock_config(430, 1);
    my $target = identity_of($class, 430);
    my $other_uid = new_uid();
    eval { prepare_restore($class, 430, $retry, $other_uid) };
    like($@, qr/^backup belongs to another guest/, 'other backup does not match');
    is(pending_of($class, 430), "uid=$earlier_uid", 'other backup: pending uid is unchanged');
    {
        local $lock_domain_error = "test error: unexpected lock\n";
        $res = PVE::GuestIdentity::adopt($class, 430, $other_uid, $retry);
    }
    is($res->{result}, 'kept', 'other backup: identity is kept');
    is_deeply(identity_of($class, 430), $target, 'other backup: identity is unchanged');
    ok(!defined(pending_of($class, 430)), 'other backup: pending uid is removed');

    # nothing to adopt, for example with 'unique'
    $first = $class->create_and_lock_config(440);
    $class->record_pending_uid(440, new_uid());
    $res = PVE::GuestIdentity::adopt($class, 440, undef, $first);
    is($res->{result}, 'skipped', 'nothing to adopt: skipped');
    ok(!defined(pending_of($class, 440)), 'nothing to adopt: pending uid is removed');

    # adopting fails
    $first = $class->create_and_lock_config(450);
    $backup_uid = new_uid();
    $class->record_pending_uid(450, $backup_uid);
    {
        local $lock_domain_error = "cfs-lock 'domain-guest-identity' error: no quorum!\n";
        eval { PVE::GuestIdentity::adopt($class, 450, $backup_uid, $first) };
        is($@, $lock_domain_error, 'lock error is passed on');
    }
    is_deeply(identity_of($class, 450), $first->{assigned},
        'lock error: identity is unchanged');
    is(
        pending_of($class, 450),
        "uid=$backup_uid",
        'lock error: nothing decided, pending uid stays',
    );

    unlock_config($class, 450);
    $retry = $class->create_and_lock_config(450, 1);
    $res = PVE::GuestIdentity::adopt($class, 450, $backup_uid, $retry);
    is($res->{result}, 'adopted', 'lock error: a later operation adopts the pending uid');
    ok(!defined(pending_of($class, 450)), 'lock error: then the pending uid is removed');

    # removing the pending uid keeps a stored identity that the parser could not read
    my $config_module = Test::MockModule->new('PVE::TestConfig', no_auto => 1);
    $config_module->mock(
        load_config => sub {
            my $conf = $config_module->original('load_config')->(@_);
            delete $conf->{meta};
            return $conf;
        },
    );
    $class->write_config(470, { name => 'target', meta => 'ctime=1' });
    $target = identity_of($class, 470);
    $retry = $class->create_and_lock_config(470, 1);
    $class->record_pending_uid(470, new_uid());
    {
        local $lock_domain_error = "test error: unexpected lock\n";
        $res = PVE::GuestIdentity::adopt($class, 470, new_uid(), $retry);
    }
    $config_module->unmock('load_config');
    is($res->{result}, 'kept', 'unreadable meta: identity is kept');
    ok(!defined(pending_of($class, 470)), 'unreadable meta: pending uid is removed');
    is_deeply(identity_of($class, 470), $target, 'unreadable meta: stored identity is kept');

    # removing the pending uid fails
    $class->write_config(460, { name => 'target' });
    $retry = $class->create_and_lock_config(460, 1);
    $class->record_pending_uid(460, new_uid());
    {
        local $get_config_error = "Connection refused\n";
        eval { PVE::GuestIdentity::adopt($class, 460, new_uid(), $retry) };
        is($@, "unable to remove the pending uid - Connection refused\n", 'error is passed on');
    }
    ok(defined(pending_of($class, 460)), 'pending uid stays');

    eval { $class->record_pending_uid(460, 'GAYTEMZUGU3DOOBZMFRG') };
    like($@, qr/invalid guest identity uid/, 'invalid pending uid is refused');
};

subtest 'config view with pending changes' => sub {
    my $class = 'PVE::TestConfig';

    my $pending_uid = new_uid();
    $class->write_config(480, { name => 'old', meta => 'ctime=1' });
    my $meta = conf_of($class, 480)->{meta};
    $class->record_pending_uid(480, $pending_uid);
    my $conf = conf_of($class, 480);
    $conf->{pending}->{name} = 'new';
    $class->write_config(480, $conf);

    PVE::Cluster::cfs_update();
    $conf = $class->load_current_config(480);
    is($conf->{name}, 'new', 'other pending change is shown');
    is($conf->{meta}, $meta, 'pending uid is not shown as meta');
    ok(!exists($conf->{pending}), 'no pending section');
    is($class->load_current_config(480, 1)->{name}, 'old', 'current values only');

    set_file($class, 481, "meta: $meta\nname: old\n\n[PENDING]\ndelete: meta\n");
    PVE::Cluster::cfs_update();
    is($class->load_current_config(481)->{meta}, $meta, 'pending deletion of meta not shown');

    # a guest type without identities may apply pending changes of 'meta'
    $class = 'PVE::TestConfig::NoIdentity';
    set_file($class, 482, "meta: ctime=1\nname: old\n\n[PENDING]\nmeta: ctime=2\n");
    PVE::Cluster::cfs_update();
    is($class->load_current_config(482)->{meta}, 'ctime=2', 'without identities: shown');
};

subtest 'drop pending meta' => sub {
    my $class = 'PVE::TestConfig';
    my $uid = new_uid();

    my $uid_dropped = "guest identity: dropping pending uid $uid of an unfinished restore - a"
        . " retry now needs 'allow-identity-mismatch'\n";
    my $ignored = "ignoring pending change of read-only option 'meta'\n";
    my $tests = [
        ['pending uid', { meta => "uid=$uid", name => 'new' }, { name => 'new' }, $uid_dropped],
        ['other change', { meta => 'ctime=2', name => 'new' }, { name => 'new' }, $ignored],
        ['deletion', { delete => 'meta,name' }, { delete => 'name' }, $ignored],
        ['uid and deletion', { meta => "uid=$uid", delete => 'meta' }, {}, $uid_dropped],
        ['no change of meta', { name => 'new' }, { name => 'new' }, ''],
    ];

    for my $test (@$tests) {
        my ($name, $pending, $expected, $expected_warning) = @$test;
        my $conf = { meta => 'ctime=1', name => 'old', pending => { $pending->%* } };

        my $warnings = '';
        local $SIG{__WARN__} = sub { $warnings .= $_[0]; };
        $class->drop_pending_meta($conf);

        is_deeply(
            $conf,
            { meta => 'ctime=1', name => 'old', pending => $expected },
            "$name: only a change of meta is dropped",
        );
        is($warnings, $expected_warning, "$name: warning");
    }
};

# Runs $code with the output to STDOUT captured, returns the error and the output.
my sub capture_output($code) {
    my $output = '';
    open(my $fh, '>', \$output) or die "unable to capture output - $!\n";
    my $previous_fh = select($fh);
    eval { $code->() };
    my $err = $@;
    select($previous_fh);
    close($fh);

    return ($err, $output);
}

subtest 'tunnel identity command on the target' => sub {
    my $class = 'PVE::TestConfig';

    # validates the parameters like the tunnel endpoints do, returns the error, output and reply
    my $handle = sub($state, $reservation, $params) {
        my $schema = {
            type => 'object',
            properties => PVE::GuestIdentity::tunnel_identity_cmd_schema(),
            additionalProperties => 0,
        };
        my $reply;
        my ($err, $output) = capture_output(sub {
            PVE::JSONSchema::validate($params, $schema);
            $reply =
                PVE::GuestIdentity::handle_tunnel_identity($class, $state, $reservation, $params);
        });
        return ($err, $output, $reply);
    };
    my $once = "the uid can only be adopted once, before the config arrives\n";

    my $uid = new_uid();
    my $reservation = $class->create_and_lock_config(600);
    my $state = { vmid => 600, lock => 'create' };
    my ($err, $output, $reply) = $handle->($state, $reservation, { uid => $uid });
    is($err, '', 'free uid: accepted');
    is_deeply(
        $reply,
        { identity => { result => 'adopted', uid => $uid, requested => $uid } },
        'free uid: reply',
    );
    is($output, "guest identity: adopted uid $uid from the source guest\n", 'free uid: logged');
    is(identity_of($class, 600)->{uid}, $uid, 'free uid: stored');

    ($err) = $handle->($state, $reservation, { uid => new_uid() });
    is($err, $once, 'second command is refused');
    is(identity_of($class, 600)->{uid}, $uid, 'second command: uid is unchanged');

    $reservation = $class->create_and_lock_config(601);
    my $reserved = identity_of($class, 601);
    ($err) = $handle->({ vmid => 601, lock => 'migrate' }, $reservation, { uid => new_uid() });
    is($err, $once, 'command after the config is refused');
    is_deeply(identity_of($class, 601), $reserved, 'after the config: identity is kept');

    ($err, $output) =
        $handle->({ vmid => 601, lock => 'create' }, $reservation, { uid => $uid });
    is(
        $err,
        "guest 600 in the target cluster already has the uid '$uid' of this guest - use"
            . " 'allow-new-uid' to migrate it with a new uid\n",
        'uid in use: refused',
    );
    is($output, '', 'uid in use: no result logged');
    is_deeply(identity_of($class, 601), $reserved, 'uid in use: reserved identity stays');

    ($err, $output, $reply) = $handle->(
        { vmid => 601, lock => 'create' },
        $reservation,
        { uid => $uid, 'allow-new-uid' => 1 },
    );
    is($err, '', 'uid in use with allow-new-uid: accepted');
    is_deeply(
        $reply,
        {
            identity => {
                result => 'in-use',
                uid => $reserved->{uid},
                requested => $uid,
                'in-use-by' => 600,
            },
        },
        'uid in use with allow-new-uid: reply',
    );
    is(
        $output,
        "guest identity: source guest uid $uid is in use by guest 600, keeping uid"
            . " $reserved->{uid}\n",
        'uid in use with allow-new-uid: logged',
    );
    is_deeply(identity_of($class, 601), $reserved, 'uid in use with allow-new-uid: kept');

    $reservation = $class->create_and_lock_config(602);
    {
        local $lock_domain_error = "cfs-lock 'domain-guest-identity' error: no quorum!\n";
        ($err) =
            $handle->({ vmid => 602, lock => 'create' }, $reservation, { uid => new_uid() });
    }
    is(
        $err,
        "unable to adopt the uid of the source guest - cfs-lock 'domain-guest-identity' error:"
            . " no quorum!\n",
        'lock error is passed on',
    );

    # what the 'config' command logs if no 'identity' command came before it
    $reservation = $class->create_and_lock_config(604);
    $state = { vmid => 604, lock => 'create' };
    my $log_not_sent =
        sub { PVE::GuestIdentity::log_tunnel_identity_not_sent($state, $reservation) };
    (undef, $output) = capture_output($log_not_sent);
    my $assigned = $reservation->{assigned}->{uid};
    like(
        $output,
        qr/^guest identity: the source sent no uid, .* has the new uid $assigned\n/,
        'no identity command: the new uid is logged',
    );
    like($output, qr/ migration back there gets refused\n$/, 'and the consequence');
    $handle->($state, $reservation, { uid => new_uid() });
    (undef, $output) = capture_output($log_not_sent);
    is($output, '', 'after an identity command: nothing is logged');

    $reservation = $class->create_and_lock_config(603);
    ($err) = $handle->({ vmid => 603, lock => 'create' }, $reservation, {});
    like($err, qr/^uid: property is missing/m, 'missing uid is refused');
    ($err) =
        $handle->({ vmid => 603, lock => 'create' }, $reservation, { uid => $uid, x => 1 });
    like($err, qr/^x: property is not defined in schema/m, 'unknown parameter is refused');

    delete PVE::GuestIdentity::tunnel_identity_cmd_schema()->{uid};
    ok(PVE::GuestIdentity::tunnel_identity_cmd_schema()->{uid}, 'schema is a new copy');

    my $option = PVE::JSONSchema::get_standard_option('pve-guest-allow-new-uid');
    is($option->{type}, 'boolean', 'the override is a standard option');
};

subtest 'tunnel identity command on the source' => sub {
    my $class = 'PVE::TestConfig';

    my $tunnel = { version => 3 };
    my ($commands, $reply);
    local *PVE::Tunnel::write_tunnel = sub {
        my ($used_tunnel, $timeout, $command, $params) = @_;
        push $commands->@*, [$used_tunnel, $timeout, $command, $params];
        die $reply if !ref($reply);
        return $reply;
    };

    # like the migration of the guest $vmid with the options $opts after its preparation loaded
    # the config
    my $migration = sub($vmid, $opts = {}) {
        PVE::Cluster::cfs_update();
        my $conf = $class->load_config($vmid);
        return bless { vmid => $vmid, vmconf => $conf, opts => $opts }, 'PVE::AbstractMigrate';
    };
    # returns the error, the output, and the sent parameters
    my $send = sub($name, $migrate) {
        $commands = [];
        my ($err, $output) =
            capture_output(sub { $migrate->adopt_identity_on_target($class, $tunnel) });
        my @sent = map { [$_->@[0 .. 2]] } $commands->@*;
        is_deeply(\@sent, [[$tunnel, 60, 'identity']], "$name: one command, up to a minute");
        return ($err, $output, $commands->[0]->[3]);
    };

    $class->write_config(610, { name => 'source' });
    my $source = identity_of($class, 610);
    $reply =
        { identity => { result => 'adopted', uid => $source->{uid}, requested => $source->{uid} } };
    my $writes_before = $writes;
    my ($err, $output, $params) = $send->('source with uid', $migration->(610));
    is($err, '', 'source with uid: no error');
    is_deeply($params, { uid => $source->{uid}, 'allow-new-uid' => 0 },
        'source with uid: sent');
    is($writes, $writes_before, 'source with uid: nothing is written');
    like(
        $output,
        qr/^\S+ \S+ guest identity: the migrated guest keeps uid $source->{uid}\n\z/,
        'source with uid: result is logged',
    );

    $reply = {
        identity => {
            result => 'in-use',
            uid => 'targettargettargetta',
            requested => $source->{uid},
            'in-use-by' => 7,
        },
    };
    ($err, $output, $params) =
        $send->('allow-new-uid', $migration->(610, { 'allow-new-uid' => 1 }));
    is($params->{'allow-new-uid'}, 1, 'allow-new-uid is sent');
    my $line =
        "guest identity: guest 7 in the target cluster has uid $source->{uid}, the migrated"
        . " guest gets the new uid targettargettargetta";
    like($output, qr/^\S+ \S+ \Q$line\E\n\z/, 'uid in use on the target: result is logged');

    set_file($class, 611, "name: source\n");
    my $migrate = $migration->(611);
    $reply = { success => 1 };
    $writes_before = $writes;
    ($err, $output, $params) = $send->('source without uid', $migrate);
    my $assigned = identity_of($class, 611);
    ok($assigned, 'source without uid: gets one');
    is($writes, $writes_before + 1, 'source without uid: written once');
    is($params->{uid}, $assigned->{uid}, 'source without uid: sends the uid it got');
    is_deeply(
        $class->get_identity($migrate->{vmconf}),
        $assigned,
        'source without uid: loaded config has it',
    );
    is($output, '', 'source without uid: reply without result is not logged');

    my $stored_uid = new_uid();
    set_file($class, 612, "meta: ctime=1,rtime=5,uid=$stored_uid\nname: source\n");
    $migrate = $migration->(612);
    # like a parser that drops a 'meta' property with a member it does not know
    delete $migrate->{vmconf}->{meta};
    ($err, $output, $params) = $send->('stored uid only', $migrate);
    is(
        $params->{uid}, $stored_uid, 'stored uid only: sends the stored uid',
    );
    is_deeply(
        identity_of($class, 612),
        { uid => $stored_uid, rtime => 5 },
        'stored uid only: stored identity is kept',
    );

    $reply =
        { identity => { result => 'future', uid => $stored_uid, requested => $stored_uid } };
    ($err, $output) = $send->('unknown result', $migration->(612));
    is($err, '', 'unknown result: no error');
    like(
        $output,
        qr/ guest identity: unknown result 'future' of the target$/m,
        'unknown result: warning',
    );

    $reply = "error - tunnel command 'identity' failed - refused\n";
    ($err, $output) = $send->('failed command', $migration->(612));
    is($err, $reply, 'failed command: error is passed on');
};

done_testing();
