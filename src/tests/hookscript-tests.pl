#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use File::Temp qw(tempdir);
use Test::More;

use PVE::GuestHelpers;
use PVE::Tools;

my $dir = tempdir(CLEANUP => 1);
my $script = "$dir/hookscript";
my $stderr_file = "$dir/stderr";

{
    no warnings 'redefine';
    *PVE::GuestHelpers::check_hookscript = sub { return $script; };
}

my $tests = [
    {
        name => 'former example rejecting the phase',
        body => q{echo "got unknown phase 'new-phase'" >&2; exit 255},
        stop_on_error => 1,
        stderr => "got unknown phase 'new-phase'\n",
    },
    {
        name => 'former example rejecting the phase without stop on error',
        body => q{echo "got unknown phase 'new-phase'" >&2; exit 255},
        stop_on_error => 0,
        stderr => "got unknown phase 'new-phase'\n",
    },
    {
        name => 'failure naming another phase',
        body => q{echo "got unknown phase 'other-phase'" >&2; exit 1},
        stop_on_error => 1,
        dies => 1,
        stderr => "got unknown phase 'other-phase'\n",
    },
    {
        name => 'failure with a message only containing the known one',
        body => q{echo "error: got unknown phase 'new-phase'" >&2; exit 1},
        stop_on_error => 1,
        dies => 1,
        stderr => "error: got unknown phase 'new-phase'\n",
    },
    {
        name => 'failure after a warning about the phase',
        body => q{echo "got unknown phase 'new-phase'" >&2; echo 'cleanup failed' >&2; exit 1},
        stop_on_error => 1,
        dies => 1,
        stderr => "got unknown phase 'new-phase'\ncleanup failed\n",
    },
    {
        name => 'failure without a message',
        body => 'exit 1',
        stop_on_error => 1,
        dies => 1,
        stderr => '',
    },
    {
        name => 'failure without stop on error',
        body => 'exit 1',
        stop_on_error => 0,
        warns => 1,
        stderr => '',
    },
    {
        name => 'success with a warning from the script',
        body => q{echo "got unknown phase 'new-phase'" >&2},
        stop_on_error => 1,
        stderr => "got unknown phase 'new-phase'\n",
    },
];

for my $test ($tests->@*) {
    my $name = $test->{name};

    open(my $fh, '>', $script) or die "unable to write script - $!\n";
    print $fh "#!/bin/sh\n$test->{body}\n";
    close($fh) or die "unable to write script - $!\n";
    chmod(0755, $script) or die "unable to make script executable - $!\n";

    open(my $saved_stderr, '>&', \*STDERR) or die "unable to save stderr - $!\n";
    open(STDERR, '>', $stderr_file) or die "unable to redirect stderr - $!\n";

    my $warning;
    eval {
        local $SIG{__WARN__} = sub { $warning = shift; };

        PVE::GuestHelpers::exec_hookscript(
            { hookscript => 'local:snippets/hookscript' },
            100,
            'new-phase',
            $test->{stop_on_error},
        );
    };
    my $err = $@;

    open(STDERR, '>&', $saved_stderr) or die "unable to restore stderr - $!\n";
    my $stderr = PVE::Tools::file_get_contents($stderr_file);

    if ($test->{dies}) {
        like($err, qr/^hookscript error for 100 on new-phase: /, "$name: aborts");
    } else {
        is($err, '', "$name: does not abort");
    }

    if ($test->{warns}) {
        like($warning, qr/^hookscript error for 100 on new-phase: /, "$name: warns");
    } else {
        is($warning, undef, "$name: does not warn");
    }

    is($stderr, $test->{stderr}, "$name: script output is kept");
}

done_testing();
