package PVE::GuestID;

use v5.36;

use PVE::Cluster qw(
    cfs_lock_file
    cfs_read_file
    cfs_register_file
    cfs_write_file
);

my $FILENAME = 'virtual-guest/used-guest-ids';

my sub parse_id_list($filename, $raw) {
    my $ranges = [];

    return $ranges if !defined($raw);

    for my $line (split(/\n/, $raw)) {
        next if $line =~ m/^\s*$/;

        if ($line =~ m/^([0-9]+)$/) {
            push $ranges->@*, [$1, $1];
        } elsif ($line =~ m/^([0-9]+)-([0-9]+)$/) {
            my ($start, $end) = ($1, $2);
            if ($start > $end) {
                warn "skipping reversed range in $filename: $line\n";
                next;
            }
            push $ranges->@*, [$start, $end];
        } else {
            warn "skipping invalid entry in $filename: $line\n";
        }
    }

    # lookup and insertion rely on the ranges being ordered by start,
    # merging adjacent and overlapping ones is done when writing the
    # id list.
    return [sort { $a->[0] <=> $b->[0] } $ranges->@*];
}

my sub format_entry($start, $last) {
    return $start == $last ? "$start\n" : "$start-$last\n";
}

my sub write_id_list($filename, $ranges) {
    my $output = '';
    my ($start, $last);

    for my $range ($ranges->@*) {
        my ($curr_start, $curr_end) = $range->@*;

        if (!defined($start)) {
            ($start, $last) = ($curr_start, $curr_end);
        } elsif ($curr_start <= $last + 1) {
            $last = $curr_end if $curr_end > $last;
        } else {
            $output .= format_entry($start, $last);
            ($start, $last) = ($curr_start, $curr_end);
        }
    }

    $output .= format_entry($start, $last) if defined($start);

    return $output;
}

# Returns the lowest ID at or above $id that is neither taken by an
# existing guest nor recorded as used before.
sub get_next_unused_id($id) {
    my $ranges = cfs_read_file($FILENAME);
    my $vmlist = PVE::Cluster::get_vmlist() // {};
    my $existing = $vmlist->{ids} // {};

    my $i = 0;
    while (1) {
        while ($i < scalar($ranges->@*) && $ranges->[$i]->[1] < $id) {
            $i++;
        }

        if ($i < scalar($ranges->@*) && $ranges->[$i]->[0] <= $id) {
            $id = $ranges->[$i]->[1] + 1;
        } elsif (defined($existing->{$id})) {
            $id++;
        } else {
            return $id;
        }
    }
}

my sub insert_id($ranges, $id) {
    my $i = 0;

    while ($i < scalar(@$ranges) && $ranges->[$i]->[1] < $id) {
        $i++;
    }

    return 0 if $i < scalar(@$ranges) && $ranges->[$i]->[0] <= $id;

    splice(@$ranges, $i, 0, [$id, $id]);

    return 1;
}

sub register_used_id($id) {
    cfs_lock_file(
        $FILENAME,
        10,
        sub {
            my $ranges = cfs_read_file($FILENAME);

            return if !insert_id($ranges, $id);

            cfs_write_file($FILENAME, $ranges);
        },
    );
    if (my $err = $@) {
        my $dc_conf = cfs_read_file('datacenter.cfg');

        my $emsg = "unable to record guest ID $id as used";
        die "$emsg - $err" if $dc_conf->{'next-id'}->{unique};
        warn "$emsg - $err";
    }
}

cfs_register_file($FILENAME, \&parse_id_list, \&write_id_list);

1;
