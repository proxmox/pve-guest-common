package PVE::ReplicationState;

use warnings;
use strict;
use JSON;

use PVE::Tools;
use PVE::ReplicationConfig;


# Note: regression tests can overwrite $state_path for testing
our $state_path = "/var/lib/pve-manager/pve-replication-state.json";
our $state_lock = "/var/lib/pve-manager/pve-replication-state.lck";

# Note: We use PVE::Tools::file_set_contents to write state file atomically,
# so read_state() always returns an consistent copy (even when not locked).

sub read_state {

    return {} if ! -e $state_path;

    my $raw = PVE::Tools::file_get_contents($state_path);

    return {} if $raw eq '';

    # untaint $raw
    if ($raw =~ m/^({.*})$/) {
	return decode_json($1);
    }

    die "invalid json data in '$state_path'\n";
}

sub extract_job_state {
    my ($stateobj, $jobcfg) = @_;

    my $plugin = PVE::ReplicationConfig->lookup($jobcfg->{type});

    my $vmid = $jobcfg->{guest};
    my $tid = $plugin->get_unique_target_id($jobcfg);
    my $state = $stateobj->{$vmid}->{$tid};

    $state = {} if !$state;

    $state->{last_iteration} //= 0;
    $state->{last_try} //= 0; # last sync start time
    $state->{last_sync} //= 0; # last successful sync start time
    $state->{fail_count} //= 0;

    return $state;
}

sub read_job_state {
    my ($jobcfg) = @_;

    my $stateobj = read_state();
    return extract_job_state($stateobj, $jobcfg);
}

sub write_job_state {
    my ($jobcfg, $state) = @_;

    my $plugin = PVE::ReplicationConfig->lookup($jobcfg->{type});

    my $vmid = $jobcfg->{guest};
    my $tid = $plugin->get_unique_target_id($jobcfg);

    my $code = sub {

	my $stateobj = read_state();
	# Note: tuple ($vmid, $tid) is unique
	$stateobj->{$vmid}->{$tid} = $state;

	PVE::Tools::file_set_contents($state_path, encode_json($stateobj));
    };

    PVE::Tools::lock_file($state_lock, 10, $code);
    die $@ if $@;
}

1;
