package PVE::GuestID;

use v5.36;

use PVE::Cluster qw(
    cfs_lock_file
    cfs_read_file
    cfs_register_file
    cfs_write_file
);

my $FILENAME = 'virtual-guest/used-guest-ids';

# keep well below the 1 MiB file size limit of pmxcfs, writes fail beyond it
my $SIZE_WARN = 512 * 1024;
my $SIZE_MAX = 768 * 1024;

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

my sub merge_ranges($ranges) {
    my $merged = [];

    for my $range ($ranges->@*) {
        my ($start, $end) = $range->@*;
        my $current_merge = $merged->[-1];

        if ($current_merge && $start <= $current_merge->[1] + 1) {
            $current_merge->[1] = $end if $end > $current_merge->[1];
        } else {
            push $merged->@*, [$start, $end];
        }
    }

    return $merged;
}

my sub format_ranges($ranges) {
    return join('', map { format_entry($_->@*) } $ranges->@*);
}

# Closes the smallest gaps between ranges in $merged until the
# formatted list of $output_size bytes fits into $SIZE_MAX. The unused
# IDs in a closed gap count as used from then on. Returns the resulting
# ranges and the number of unused IDs that got marked as used.
my sub close_smallest_gaps($merged, $output_size) {
    my @gap_sizes;
    for my $i (1 .. $#$merged) {
        my $prev_end = $merged->[$i - 1]->[1];
        my $curr_start = $merged->[$i]->[0];

        $gap_sizes[$i] = $curr_start - $prev_end - 1;
    }

    my @gap_order = sort { $gap_sizes[$a] <=> $gap_sizes[$b] || $a <=> $b } 1 .. $#$merged;

    # Record start and end of each group. Initially, with e.g. 6 ranges,
    # this would be:
    #   start: (0, 1, 2, 3, 4, 5)
    #   end:   (0, 1, 2, 3, 4, 5)
    # After closing the gap between 1 and 2:
    #   start: (0, 1, 1, 3, 4, 5)
    #   end:   (0, 2, 2, 3, 4, 5)
    # After closing the gap between 2 and 3 (note that range 2 is now fully
    # merged into adjacent ranges, so its group indices won't be accessed
    # anymore):
    #   start: (0, 1, 1, 1, 4, 5)
    #   end:   (0, 3, 2, 3, 4, 5)
    # After closing the gap between 4 and 5:
    #   start: (0, 1, 1, 1, 4, 4)
    #   end:   (0, 3, 2, 3, 5, 5)
    my @group_start = (0 .. $#$merged);
    my @group_end = (0 .. $#$merged);

    my $closed_id_count = 0;

    for my $i (@gap_order) {
        last if $output_size <= $SIZE_MAX;

        my ($first_index, $last_index) = ($group_start[$i - 1], $group_end[$i]);
        my ($new_range_start, $new_range_end) =
            ($merged->[$first_index]->[0], $merged->[$last_index]->[1]);
        # used IDs directly before and after gap $i
        my ($before_gap, $after_gap) = ($merged->[$i - 1]->[1], $merged->[$i]->[0]);

        # the lines of both groups are replaced by a single line
        # spanning them
        $output_size +=
            length(format_entry($new_range_start, $new_range_end)) -
            length(format_entry($new_range_start, $before_gap)) -
            length(format_entry($after_gap, $new_range_end));

        $group_end[$first_index] = $last_index;
        $group_start[$last_index] = $first_index;
        $closed_id_count += $gap_sizes[$i];
    }

    my $closed = [];
    for (my $i = 0; $i <= $#$merged; $i = $group_end[$i] + 1) {
        push $closed->@*, [$merged->[$i]->[0], $merged->[$group_end[$i]]->[1]];
    }

    return ($closed, $closed_id_count);
}

my sub write_id_list($filename, $ranges) {
    my $merged = merge_ranges($ranges);
    my $output = format_ranges($merged);

    if (length($output) > $SIZE_MAX) {
        my ($closed, $closed_ids) = close_smallest_gaps($merged, length($output));
        $output = format_ranges($closed);
        warn "$filename would exceed "
            . ($SIZE_MAX / 1024) . " KiB"
            . ", recorded $closed_ids unused guest IDs in the smallest"
            . " gaps as used\n";
    } elsif (length($output) > $SIZE_WARN) {
        warn "$filename is "
            . int(length($output) / 1024) . " KiB"
            . ", the smallest gaps between used guest IDs will be"
            . " closed beyond "
            . ($SIZE_MAX / 1024)
            . " KiB\n";
    }

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
