package PVE::GuestHelpers;

use strict;
use warnings;

use PVE::Tools;

# We use a separate lock to block migration while a replication job
# is running.

sub guest_migration_lock {
    my ($vmid, $timeout, $func, @param) = @_;

    my $lockid = "pve-migrate-$vmid";
    my $lockdir = "/var/lock/pve-manager";

    mkdir $lockdir;

    my $res = PVE::Tools::lock_file("$lockdir/$lockid", $timeout, $func, @param);
    die $@ if $@;

    return $res;
}

1;
