package PVE::GuestHelpers;

use strict;
use warnings;

use PVE::Exception qw(raise_perm_exc);
use PVE::Tools qw(split_list);
use PVE::Storage;

use POSIX qw(strftime);
use Scalar::Util qw(weaken);

use base qw(Exporter);

our @EXPORT_OK = qw(
assert_tag_permissions
get_allowed_tags
safe_boolean_ne
safe_num_ne
safe_string_ne
typesafe_ne
);

# We use a separate lock to block migration while a replication job
# is running.

our $lockdir = '/var/lock/pve-manager';

# safe variable comparison functions

sub safe_num_ne {
    my ($a, $b) = @_;

    return 0 if !defined($a) && !defined($b);
    return 1 if !defined($a);
    return 1 if !defined($b);

    return $a != $b;
}

sub safe_string_ne  {
    my ($a, $b) = @_;

    return 0 if !defined($a) && !defined($b);
    return 1 if !defined($a);
    return 1 if !defined($b);

    return $a ne $b;
}

sub safe_boolean_ne {
    my ($a, $b) = @_;

    # we don't check if value is defined, since undefined
    # is false (so it's a valid boolean)

    # negate both values to normalize and compare
    return !$a != !$b;
}

sub typesafe_ne {
    my ($a, $b, $type) = @_;

    return 0 if !defined($a) && !defined($b);
    return 1 if !defined($a);
    return 1 if !defined($b);

    if ($type eq 'string') {
	return safe_string_ne($a, $b);
    } elsif ($type eq 'number' || $type eq 'integer') {
	return safe_num_ne($a, $b);
    } elsif ($type eq 'boolean') {
	return safe_boolean_ne($a, $b);
    }

    die "internal error: can't compare $a and $b with type $type";
}


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

    die "script '$volid' does not exist\n"
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
    my $snapshottree_weak;
    $snapshottree_weak = sub {
	my ($prefix, $root, $snapshots) = @_;
	my $e = $snapshots->{$root};

	my $description = $e->{description} || 'no-description';
	($description) = $description =~ m/(.*)$/m;

	my $timestring = "";
	if (defined $e->{snaptime}) {
	    $timestring = strftime("%F %H:%M:%S", localtime($e->{snaptime}));
	}

	my $len = 30 - length($prefix); # for aligning the description
	$len = 0 if $len < 0;
	printf("%s %-${len}s %-23s %s\n", $prefix, $root, $timestring, $description);

	if ($e->{children}) {
	    $prefix = " $prefix";
	    foreach my $child (sort $snaptimesort @{$e->{children}}) {
		$snapshottree_weak->($prefix, $child, $snapshots);
	    }
	}
    };
    my $snapshottree = $snapshottree_weak;
    weaken($snapshottree_weak);

    foreach my $root (sort $snaptimesort @roots) {
	$snapshottree->('`->', $root, $snapshots);
    }
}

sub format_pending {
    my ($data) = @_;
    foreach my $item (sort { $a->{key} cmp $b->{key}} @$data) {
	my $k = $item->{key};
	next if $k eq 'digest';
	my $v = $item->{value};
	my $p = $item->{pending};
	if ($k eq 'description') {
	    $v = PVE::Tools::encode_text($v) if defined($v);
	    $p = PVE::Tools::encode_text($p) if defined($p);
	}
	if (defined($v)) {
	    if ($item->{delete}) {
		print "del $k: $v\n";
	    } elsif (defined($p)) {
		print "cur $k: $v\n";
		print "new $k: $p\n";
	    } else {
		print "cur $k: $v\n";
	    }
	} elsif (defined($p)) {
	    print "new $k: $p\n";
	}
    }
}

# returns the config as an array of hashes, each hash can have the following keys:
#  key: the config property name, non-optional
#  value: the current value in effect - if any
#  pending: a new, still pending, value - if any
#  delete: when deletions are pending, this is set to either 2 (force) or 1 (graceful)
sub config_with_pending_array {
    my ($conf, $pending_delete_hash) = @_;

    my $pending = delete $conf->{pending};
    # we don't care for snapshots in pending and it makes our loops throw up
    delete $conf->{snapshots};

    my $res = [];
    foreach my $opt (keys %$conf) {
	next if ref($conf->{$opt}); # e.g., "raw" lxc.* keys are added as array ref

	my $item = {
	    key => $opt,
	    value => $conf->{$opt},
	};
	$item->{pending} = delete $pending->{$opt} if defined($pending->{$opt});
	my $delete = delete $pending_delete_hash->{$opt};
	$item->{delete} = $delete->{force} ? 2 : 1 if defined($delete);

	push @$res, $item;
    }

    foreach my $opt (keys %$pending) {
	next if $opt eq 'delete';
	push @$res, {
	    key => $opt,
	    pending => $pending->{$opt},
	};
    }

    while (my ($opt, $force) = each %$pending_delete_hash) {
	push @$res, {
	    key => $opt,
	    delete => $force ? 2 : 1,
	};
    }

    return $res;
}

# returns the allowed tags for the given user
# in scalar context, returns the list of allowed tags that exist
# in list context, returns a tuple of allowed tags, privileged tags, and if freeform is enabled
#
# first parameter is a bool if the user is 'privileged' (normally Sys.Modify on /)
# second parameter is a closure which takes the vmid. should check if the user can see the vm tags
sub get_allowed_tags {
    my ($rpcenv, $user, $privileged_user) = @_;

    $privileged_user //= ($rpcenv->check($user, '/', ['Sys.Modify'], 1) // 0);

    my $datacenter_config = PVE::Cluster::cfs_read_file('datacenter.cfg');

    my $allowed_tags = {};
    my $privileged_tags = {};
    if (my $tags = $datacenter_config->{'registered-tags'}) {
	$privileged_tags->{$_} = 1 for $tags->@*;
    }
    my $user_tag_privs = $datacenter_config->{'user-tag-access'} // {};
    my $user_allow = $user_tag_privs->{'user-allow'} // 'free';
    my $freeform = $user_allow eq 'free';

    if ($user_allow ne 'none' || $privileged_user) {
	$allowed_tags->{$_} = 1 for ($user_tag_privs->{'user-allow-list'} // [])->@*;
    }

    if ($user_allow eq 'free' || $user_allow eq 'existing' || $privileged_user) {
	my $props = PVE::Cluster::get_guest_config_properties(['tags']);
	for my $vmid (keys $props->%*) {
	    next if !$privileged_user && !$rpcenv->check_vm_perm($user, $vmid, undef, ['VM.Audit'], 0, 1);
	    $allowed_tags->{$_} = 1 for split_list($props->{$vmid}->{tags});
	}
    }

    if ($privileged_user) {
	$allowed_tags->{$_} = 1 for keys $privileged_tags->%*;
    } else {
	delete $allowed_tags->{$_} for keys $privileged_tags->%*;
    }

    return wantarray ? ($allowed_tags, $privileged_tags, $freeform) : $allowed_tags;
}

# checks the permissions for setting/updating/removing tags for guests
# tagopt_old and tagopt_new expect the tags as they are in the config
#
# either returns gracefully or raises a permission exception
sub assert_tag_permissions {
    my ($vmid, $tagopt_old, $tagopt_new, $rpcenv, $authuser) = @_;

    $rpcenv->check_vm_perm($authuser, $vmid, undef, ['VM.Config.Options']);

    my $privileged_user = $rpcenv->check($authuser, '/', ['Sys.Modify'], 1) // 0;

    my ($allowed_tags, $privileged_tags, $freeform);
    my $check_single_tag = sub {
	my ($tag) = @_;
	return if $privileged_user;

	if (!defined($allowed_tags // $privileged_tags // $freeform)) { # cache
	    ($allowed_tags, $privileged_tags, $freeform) = get_allowed_tags($rpcenv, $authuser, $privileged_user);
	}

	if ((!$allowed_tags->{$tag} && !$freeform) || $privileged_tags->{$tag}) {
	    raise_perm_exc("/, Sys.Modify for modifying tag '$tag'");
	}

	return;
    };

    my ($old_tags, $new_tags, $all_tags) = ({}, {}, {});

    $all_tags->{$_} = $old_tags->{$_} += 1 for split_list($tagopt_old // '');
    $all_tags->{$_} = $new_tags->{$_} += 1 for split_list($tagopt_new // '');

    for my $tag (keys $all_tags->%*) {
	next if ($new_tags->{$tag} // 0) == ($old_tags->{$tag} // 0);
	$check_single_tag->($tag);
    }
}

sub get_unique_tags {
    my ($tags, $no_join_result) = @_;

    $tags = [ split_list($tags // '') ] if ref($tags) ne 'ARRAY';
    return !$no_join_result ? '': [] if !scalar($tags->@*);

    my $datacenter_config = PVE::Cluster::cfs_read_file('datacenter.cfg');
    my $tag_style_config = $datacenter_config->{'tag-style'} // {};
    my $case_sensitive = !!$tag_style_config->{'case-sensitive'};

    my $seen_tags = {};
    my $res = [];
    if (!defined($tag_style_config->{ordering}) || $tag_style_config->{ordering} ne 'config') {
	for my $tag ( sort { $case_sensitive ? $a cmp $b : lc($a) cmp lc($b) } $tags->@*) {
	    $tag = lc($tag) if !$case_sensitive;
	    next if $seen_tags->{$tag};
	    $seen_tags->{$tag} = 1;
	    push @$res, $tag;
	}
    } else {
	for my $tag ($tags->@*) {
	    $tag = lc($tag) if !$case_sensitive;
	    next if $seen_tags->{$tag};
	    $seen_tags->{$tag} = 1;
	    push @$res, $tag;
	}
    }

    return !$no_join_result ? join(';', $res->@*) : $res;
}

1;
