package PVE::GuestHelpers;

use strict;
use warnings;

use PVE::Tools;
use PVE::Storage;

# We use a separate lock to block migration while a replication job
# is running.

our $lockdir = '/var/lock/pve-manager';

sub guest_migration_lock {
    my ($vmid, $timeout, $func, @param) = @_;

    my $lockid = "pve-migrate-$vmid";

    mkdir $lockdir;

    my $res = PVE::Tools::lock_file("$lockdir/$lockid", $timeout, $func, @param);
    die $@ if $@;

    return $res;
}

sub check_hookscript {
    my ($volid, $storecfg) = @_;

    $storecfg = PVE::Storage::config() if !defined($storecfg);
    my ($path, undef, $type) = PVE::Storage::path($storecfg, $volid);

    die "'$volid' is not in the snippets directory\n"
	if $type ne 'snippets';

    die "script '$volid' does not exists\n"
	if ! -f $path;

    die "script '$volid' is not executable\n"
	if ! -x $path;

    return $path;
}

sub exec_hookscript {
    my ($conf, $vmid, $phase, $stop_on_error) = @_;

    return if !$conf->{hookscript};
    my $hookscript = eval { check_hookscript($conf->{hookscript}) };
    if (my $err = $@) {
	if ($stop_on_error) {
	    die $err;
	} else {
	    warn $err;
	    return;
	}
    }

    eval {
	PVE::Tools::run_command([$hookscript, $vmid, $phase]);
    };

    if (my $err = $@) {
	my $errmsg = "hookscript error for $vmid on $phase: $err\n";
	if ($stop_on_error) {
	    die $errmsg;
	} else {
	    warn $errmsg;
	}
    }
}

1;
