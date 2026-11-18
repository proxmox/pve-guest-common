#!/usr/bin/perl

use v5.36;

use lib qw(..);

use File::Temp qw(tempdir);
use Storable qw(retrieve store);
use Test::MockModule;
use Test::More;

use PVE::AbstractConfig;

my $tmpdir = tempdir('config-reservation-XXXXXX', DIR => '.', CLEANUP => 1);

# a guest config class that keeps its parsed configs as files in the temporary directory

package PVE::TestConfig {
    use base qw(PVE::AbstractConfig);

    sub guest_type { return 'VM'; }

    sub config_file_lock($class, $vmid) {
        return "$tmpdir/$vmid.lock";
    }

    sub cfs_config_path($class, $vmid, $node = undef) {
        return "$vmid.conf";
    }

    sub config_file($class, $vmid, $node = undef) {
        return "$tmpdir/" . $class->cfs_config_path($vmid, $node);
    }
}

package main;

my $class = 'PVE::TestConfig';

my $cluster_module = Test::MockModule->new('PVE::Cluster');
$cluster_module->redefine(
    cfs_update => sub { },
    cfs_read_file => sub {
        my ($path) = @_;
        return -e "$tmpdir/$path" ? retrieve("$tmpdir/$path") : undef;
    },
    cfs_write_file => sub {
        my ($path, $conf) = @_;
        store($conf, "$tmpdir/$path");
        return;
    },
    check_vmid_unused => sub {
        my ($vmid, $noerr) = @_;
        return 1 if !-e $class->config_file($vmid);
        return undef if $noerr;
        die "VM $vmid already exists on node 'local'\n";
    },
);

# recording used guest IDs needs the cluster filesystem
my $guest_id_module = Test::MockModule->new('PVE::GuestID');
$guest_id_module->redefine(register_used_id => sub { });

my sub conf_of($vmid) {
    return -e $class->config_file($vmid) ? $class->load_config($vmid) : undef;
}

subtest 'create and lock config' => sub {
    $class->create_and_lock_config(100);
    is_deeply(conf_of(100), { lock => 'create' }, 'free VMID: reserved');

    eval { $class->create_and_lock_config(100) };
    like($@, qr/^VM 100 already exists/, 'existing config: refused by default');

    $class->write_config(101, { name => 'target' });
    $class->create_and_lock_config(101, 1, 'restore');
    is_deeply(conf_of(101), { name => 'target', lock => 'restore' },
        'existing config: allowed');

    eval { $class->create_and_lock_config(101, 1) };
    is($@, "VM is locked (restore)\n", 'locked config: refused');

    $class->create_and_lock_config(102, 1);
    is_deeply(
        conf_of(102),
        { lock => 'create' },
        'free VMID, existing config allowed: reserved',
    );

    $class->write_config(103, { name => 'target' });
    $class->create_and_lock_config(103, 'require');
    is_deeply(conf_of(103), { name => 'target', lock => 'create' },
        'required config: reserved');

    eval { $class->create_and_lock_config(104, 'require') };
    is(
        $@,
        "Configuration file '104.conf' does not exist\n",
        'required config is missing: refused',
    );
    ok(!defined(conf_of(104)), 'required config is missing: nothing is written');
};

done_testing();
