package PVE::GuestHelpers;

use strict;
use warnings;

use PVE::Tools;
use PVE::Storage;

use POSIX qw(strftime);

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

    eval {
	my $hookscript = check_hookscript($conf->{hookscript});
	die $@ if $@;

	PVE::Tools::run_command([$hookscript, $vmid, $phase]);
    };
    if (my $err = $@) {
	my $errmsg = "hookscript error for $vmid on $phase: $err\n";
	die $errmsg if ($stop_on_error);
	warn $errmsg;
    }
}

# takes a snapshot list (e.g., qm/pct snapshot_list API call result) and
# prints it out in a nice tree sorted by age. Can cope with multiple roots
sub print_snapshot_tree {
    my ($snapshot_list) = @_;

    my $snapshots = { map { $_->{name} => $_ } @$snapshot_list };

    my @roots;
    foreach my $e (@$snapshot_list) {
	my $parent;
	if (($parent = $e->{parent}) && defined $snapshots->{$parent}) {
	    push @{$snapshots->{$parent}->{children}}, $e->{name};
	} else {
	    push @roots, $e->{name};
	}
    }

    # sort the elements by snaptime - with "current" (no snaptime) highest
    my $snaptimesort = sub {
	return +1 if !defined $snapshots->{$a}->{snaptime};
	return -1 if !defined $snapshots->{$b}->{snaptime};
	return $snapshots->{$a}->{snaptime} <=> $snapshots->{$b}->{snaptime};
    };

    # recursion function for displaying the tree
    my $snapshottree;
    $snapshottree = sub {
	my ($prefix, $root, $snapshots) = @_;
	my $e = $snapshots->{$root};

	my $description = $e->{description} || 'no-description';
	($description) = $description =~ m/(.*)$/m;

	my $timestring = "";
	if (defined $e->{snaptime}) {
	    $timestring = strftime("%F %H:%M:%S", localtime($e->{snaptime}));
	}

	my $len = 30 - length($prefix); # for aligning the description
	printf("%s %-${len}s %-23s %s\n", $prefix, $root, $timestring, $description);

	if ($e->{children}) {
	    $prefix = "    $prefix";
	    foreach my $child (sort $snaptimesort @{$e->{children}}) {
		$snapshottree->($prefix, $child, $snapshots);
	    }
	}
    };

    foreach my $root (sort $snaptimesort @roots) {
	$snapshottree->('`->', $root, $snapshots);
    }
}

1;
