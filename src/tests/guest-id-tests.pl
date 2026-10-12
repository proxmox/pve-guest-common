#!/usr/bin/perl

use v5.36;

use lib qw(..);

use List::Util qw(min sum0);
use Test::MockModule;
use Test::More;

my $FILE = '/etc/pve/virtual-guest/used-guest-ids';

# must match the thresholds in PVE::GuestID
my $SIZE_WARN = 512 * 1024;
my $SIZE_MAX = 768 * 1024;

my ($parse, $write);
my $raw; # contents of the mocked used-guest-ids file
my $writes = 0;
my $injected_write_error;
my $vmlist;
my $dc_conf = {};

my $pve_cluster_module = Test::MockModule->new('PVE::Cluster');
$pve_cluster_module->mock(
    cfs_register_file => sub($filename, $parser, $writer) {
        ($parse, $write) = ($parser, $writer);
    },
    cfs_read_file => sub($filename) {
        return $dc_conf if $filename eq 'datacenter.cfg';
        return $parse->("/etc/pve/$filename", $raw);
    },
    cfs_write_file => sub($filename, $data) {
        die $injected_write_error if defined($injected_write_error);
        $writes++;
        $raw = $write->("/etc/pve/$filename", $data);
    },
    cfs_lock_file => sub($filename, $timeout, $code) {
        return eval { $code->() };
    },
    get_vmlist => sub() { return $vmlist },
);

# not 'use', since PVE::GuestID registers the parser and writer via cfs_register_file() when
# loaded, so the mock above must be in place first to capture them
require PVE::GuestID;

sub range_to_vmlist(@ids) {
    return { ids => { map { $_ => { node => 'localhost', type => 'qemu' } } @ids } };
}

# single IDs from 100 upwards, with the gaps between them cycling through @gaps
sub single_ids($count, @gaps) {
    my @lines;
    my $id = 100;
    for my $i (0 .. $count - 1) {
        push @lines, "$id\n";
        $id += 1 + $gaps[$i % scalar(@gaps)];
    }
    return join('', @lines);
}

sub gap_sizes($ranges) {
    my @gap_sizes;
    for my $i (1 .. $#$ranges) {
        push @gap_sizes, $ranges->[$i]->[0] - $ranges->[$i - 1]->[1] - 1;
    }
    return @gap_sizes;
}

# whether every range in $inner lies within a range in $outer, both sorted
sub covers($outer, $inner) {
    my $i = 0;
    for my $range ($inner->@*) {
        while ($i < scalar(@$outer) && $outer->[$i]->[1] < $range->[0]) {
            $i++;
        }
        return 0 if $i >= scalar(@$outer);
        return 0 if $outer->[$i]->[0] > $range->[0] || $outer->[$i]->[1] < $range->[1];
    }
    return 1;
}

subtest 'parse' => sub {
    my $tests = [
        ['canonical file', "100-250\n300\n900-1200\n", [[100, 250], [300, 300], [900, 1200]]],
        [
            'unordered file is sorted but not merged',
            "300-400\n100-200\n201-250\n150-160\n",
            [[100, 200], [150, 160], [201, 250], [300, 400]],
        ],
        ['missing newline', "100-250\n300\n900-1000", [[100, 250], [300, 300], [900, 1000]]],
        ['missing file', undef, []],
        ['empty file', '', []],
        ['blank lines only', "\n  \n", []],
    ];

    for my $test ($tests->@*) {
        my ($name, $input, $expected) = $test->@*;
        is_deeply($parse->($FILE, $input), $expected, $name);
    }

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    is_deeply(
        $parse->($FILE, "100\nfoo\n50-10\n200\n"),
        [[100, 100], [200, 200]],
        'invalid entry and reversed range are skipped',
    );
    is_deeply(
        \@warnings,
        [
            "skipping invalid entry in $FILE: foo\n",
            "skipping reversed range in $FILE: 50-10\n",
        ],
        'skipped entries are warned about',
    );
};

subtest 'write' => sub {
    my $tests = [
        [
            'canonical file is written unchanged',
            "100-250\n300\n900-1200\n",
            "100-250\n300\n900-1200\n",
        ],
        [
            'overlapping and adjacent ranges are merged',
            "300-400\n100-200\n201-250\n150-160\n",
            "100-250\n300-400\n",
        ],
        ['adjacent single IDs are merged', "100\n101\n102\n", "100-102\n"],
        ['contained range keeps its container', "100-500\n200-300\n", "100-500\n"],
        [
            'ranges with adjacent IDs are merged',
            "1000-1004\n999\n100-200\n1005\n",
            "100-200\n999-1005\n",
        ],
        ['nothing recorded', '', ''],
    ];

    for my $test ($tests->@*) {
        my ($name, $input, $expected) = $test->@*;
        is($write->($FILE, $parse->($FILE, $input)), $expected, $name);
    }
};

subtest 'write size limit' => sub {
    my sub write_with_warnings($input) {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        my $output = $write->($FILE, $parse->($FILE, $input));
        return ($output, \@warnings);
    }

    my $small = single_ids(50_000, 1);
    ok(length($small) < $SIZE_WARN, 'small list is below the warning threshold');
    my ($output, $warnings) = write_with_warnings($small);
    is($output, $small, 'below the warning threshold: written unchanged');
    is_deeply($warnings, [], 'below the warning threshold: no warning');

    my $medium = single_ids(90_000, 1);
    ok(length($medium) > $SIZE_WARN && length($medium) < $SIZE_MAX,
        'medium list is in between');
    ($output, $warnings) = write_with_warnings($medium);
    is($output, $medium, 'above the warning threshold: written unchanged');
    is(scalar($warnings->@*), 1, 'above the warning threshold: one warning');
    like(
        $warnings->[0],
        qr/^\Q$FILE\E is \d+ KiB, .* closed beyond 768 KiB\n\z/,
        'above the warning threshold: size is warned about',
    );

    # above the hard limit, equal gaps
    my $large = single_ids(150_000, 1);
    ok(length($large) > $SIZE_MAX, 'large list is above the limit');
    my $input = $parse->($FILE, $large);
    ($output, $warnings) = write_with_warnings($large);
    my $closed = $parse->($FILE, $output);
    ok(length($output) <= $SIZE_MAX, 'above the limit: output fits');
    ok(covers($closed, $input), 'above the limit: every used ID is still recorded');
    is(scalar($warnings->@*), 1, 'above the limit: one warning');
    my ($count) =
        ($warnings->[0] // '') =~ m/would exceed 768 KiB, recorded (\d+) unused guest IDs? /;
    is(
        $count,
        sum0(gap_sizes($input)) - sum0(gap_sizes($closed)),
        'above the limit: number of IDs marked as used is reported',
    );

    # above the hard limit, mixed gaps
    my $mixed = single_ids(200_000, 1, 2, 5, 50);
    $input = $parse->($FILE, $mixed);
    ($output, $warnings) = write_with_warnings($mixed);
    $closed = $parse->($FILE, $output);
    my @remaining = gap_sizes($closed);
    ok(length($output) <= $SIZE_MAX, 'mixed gaps: output fits');
    ok(covers($closed, $input), 'mixed gaps: every used ID is still recorded');
    is(min(@remaining), 5, 'mixed gaps: all gaps of 1 and 2 are closed first');
    is(
        scalar(grep { $_ == 50 } @remaining),
        scalar(grep { $_ == 50 } gap_sizes($input)),
        'mixed gaps: the largest gaps are kept',
    );
};

subtest 'get_next_unused_id' => sub {
    my $tests = [
        # name, file contents, existing guests, input ID, expected ID
        ['below all ranges', "101-200\n300-400\n", [], 100, 100],
        ['start of a range', "100-200\n300-400\n", [], 100, 201],
        ['inside a range', "100-200\n300-400\n", [], 150, 201],
        ['in a gap', "100-200\n300-400\n", [], 250, 250],
        ['above all ranges', "100-200\n300-400\n", [], 500, 500],
        ['across adjacent ranges', "100-200\n201-300\n", [], 150, 301],
        ['existing guests are skipped', "100-105\n", [106, 107], 100, 108],
        ['used range after an existing guest', "100-105\n107-110\n", [106], 100, 111],
        ['existing guests not recorded in the file', '', [100, 101], 100, 102],
        ['no vmlist', "100-105\n", undef, 100, 106],
        ['nothing recorded, no guests', undef, [], 100, 100],
    ];

    for my $test ($tests->@*) {
        my ($name, $file, $existing, $id, $expected) = $test->@*;

        $raw = $file;
        $vmlist = defined($existing) ? range_to_vmlist($existing->@*) : undef;

        is(PVE::GuestID::get_next_unused_id($id), $expected, $name);
    }
};

subtest 'register_used_id' => sub {
    $raw = undef;

    my $steps = [
        ['first ID', 101, "101\n"],
        ['extends a range at its end', 102, "101-102\n"],
        ['starts a new range after a gap', 104, "101-102\n104\n"],
        ['bridges two ranges', 103, "101-104\n"],
        ['extends a range at its start', 100, "100-104\n"],
    ];

    for my $step ($steps->@*) {
        my ($name, $id, $expected) = $step->@*;
        PVE::GuestID::register_used_id($id);
        is($raw, $expected, $name);
    }

    $writes = 0;
    PVE::GuestID::register_used_id(101);
    PVE::GuestID::register_used_id(104);
    is($writes, 0, 'already recorded IDs are not written again');
    is($raw, "100-104\n", 'file unchanged by already recorded IDs');

    $raw = "300-400\n100-200\n201-250\n150-160\n";
    PVE::GuestID::register_used_id(275);
    is($raw, "100-250\n275\n300-400\n", 'unordered file is normalized on write');
};

subtest 'register_used_id errors' => sub {
    my $tests = [
        # name, datacenter.cfg, whether the error reaches the caller
        ['unique IDs requested', { 'next-id' => { unique => 1 } }, 1],
        ['unique IDs not requested', { 'next-id' => { lower => 100 } }, 0],
        ['no next-id settings', {}, 0],
    ];

    for my $test ($tests->@*) {
        my ($name, $conf, $expect_fatal) = $test->@*;

        $dc_conf = $conf;
        $raw = "100\n";
        $injected_write_error = "write failed\n";

        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };

        eval { PVE::GuestID::register_used_id(500) };

        if ($expect_fatal) {
            is(
                $@,
                "unable to record guest ID 500 as used - write failed\n",
                "$name: error is passed on to the caller",
            );
            is_deeply(\@warnings, [], "$name: no warning");
        } else {
            is($@, '', "$name: error is not passed on");
            is_deeply(
                \@warnings,
                ["unable to record guest ID 500 as used - write failed\n"],
                "$name: error is warned about",
            );
        }
        is($raw, "100\n", "$name: file unchanged");
    }

    $injected_write_error = undef;
    $dc_conf = {};
};

done_testing();
