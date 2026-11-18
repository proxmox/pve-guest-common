#!/usr/bin/perl

use v5.36;

use lib qw(..);

use POSIX ();
use Test::MockModule;
use Test::More;

use PVE::StorageTunnel;

my $volid = 'local:100/vm-100-disk-0.raw';

my $storage_module = Test::MockModule->new('PVE::Storage');
$storage_module->redefine(
    volume_import_start => sub { die "no matching import/export format found\n"; },
    config => sub { return {}; },
    storage_config => sub { return {}; },
);

my $state = { storecfg => {}, vmid => 100 };
eval {
    PVE::StorageTunnel::handle_disk_import(
        $state,
        { storage => 'local', format => 'raw', volname => 'vm-100-disk-0' },
    );
};
like($@, qr/^no matching import\/export format found/, 'import that fails to start: error');
ok(!exists($state->{disk_import}), 'import that fails to start: no entry');

eval { PVE::StorageTunnel::handle_query_disk_import($state, {}) };
is($@, "no disk import running\n", 'query without import: error');
ok(!exists($state->{disk_import}), 'query without import: no entry');

# an import that has exited, and whose last line only arrives after the first read gave up
my $pid = fork() // die "fork failed - $!\n";
POSIX::_exit(0) if !$pid;
waitpid($pid, 0);

my $output = PVE::Storage::volume_imported_message($volid);
open(my $fh, '<', \$output) or die "unable to open the import output - $!\n";
$state = { disk_import => { pid => $pid, fh => $fh, socket => '/nonexistent/import.sock' } };

my $reads = 0;
my $tools_module = Test::MockModule->new('PVE::Tools');
$tools_module->redefine(
    run_with_timeout => sub {
        my ($timeout, $code) = @_;
        return $reads++ ? $code->() : undef;
    },
);

my $warnings = '';
my $res = do {
    local $SIG{__WARN__} = sub { $warnings .= $_[0]; };
    open(my $null, '>', '/dev/null') or die "unable to open /dev/null - $!\n";
    my $stdout = select($null);
    my $res = eval { PVE::StorageTunnel::handle_query_disk_import($state, {}) };
    select($stdout);
    $res;
};
is($@, '', 'import that exited: no error');
is_deeply($res, { status => 'complete', volid => $volid }, 'import that exited: complete');
is($warnings, '', 'import that exited: no warning');
ok(!exists($state->{disk_import}), 'import that exited: no entry');
is_deeply($state->{cleanup}->{volumes}, { $volid => 1 }, 'import that exited: volume is recorded');

# waiting for a running import: a fake clock that only the pauses of the wait advance

my $now = 1_700_000_000;
my $pauses = 0;
my $time_module = Test::MockModule->new('Time::HiRes');
$time_module->redefine(
    time => sub { return $now; },
    usleep => sub {
        my ($us) = @_;
        die "test error: the wait does not end\n" if ++$pauses > 10_000;
        $now += $us / 1_000_000;
        return $us;
    },
);

# the import ends with the query number $ends_after, a query dies with $query_error if set
my ($queries, $ends_after, $query_error);
my $tunnel_module = Test::MockModule->new('PVE::StorageTunnel');
$tunnel_module->redefine(
    handle_query_disk_import => sub {
        my ($state) = @_;
        $queries++;
        die $query_error if defined($query_error);
        return { status => 'pending' } if !defined($ends_after) || $queries < $ends_after;
        delete $state->{disk_import};
        $state->{cleanup}->{volumes}->{$volid} = 1;
        return { status => 'complete', volid => $volid };
    },
);

# Waits for the disk import of the tunnel state $state, by default a new one with an import, and
# returns the error, the warnings, the state and the time waited.
my sub wait_for_import($ends, $error = undef, $timeout = undef, $state = undef) {
    ($queries, $ends_after, $query_error, $pauses) = (0, $ends, $error, 0);
    $state //= { disk_import => { pid => 1 } };
    my $start = $now;

    my $warnings = '';
    local $SIG{__WARN__} = sub { $warnings .= $_[0]; };
    eval { PVE::StorageTunnel::wait_for_disk_import($state, $timeout) };

    return ($@, $warnings, $state, $now - $start);
}

my ($err, $waited);

($err, $warnings, $state, $waited) = wait_for_import(1);
is($err, '', 'import that ends: no error');
is($queries, 1, 'import that ends: collected with one query');
is($waited, 0, 'import that ends: no pause');
is_deeply($state->{cleanup}->{volumes}, { $volid => 1 }, 'import that ends: volume is recorded');

# an import that closed its output can be queried many times before it has exited
($err, $warnings, $state, $waited) = wait_for_import(20);
is($err, '', 'import that exits late: no error');
is($queries, 20, 'import that exits late: queried until it ends');
is($pauses, 19, 'import that exits late: pause after each pending query');
ok(!$state->{disk_import}, 'import that exits late: collected');

($err, $warnings, $state) = wait_for_import(undef, "unable to query the import\n");
is($err, "a volume transfer is still running\n", 'import that cannot be collected: error');
is($warnings, "unable to query the import\n", 'import that cannot be collected: query error');
is($queries, 1, 'import that cannot be collected: no further query');
ok(!$state->{cleanup}, 'import that cannot be collected: no volume is recorded');

($err, $warnings, $state, $waited) = wait_for_import(undef);
is($err, "a volume transfer is still running\n", 'import that stays pending: error');
ok($waited >= 60 && $waited < 60.2, 'import that stays pending: waits until the deadline');
is($warnings, '', 'import that stays pending: no warning');

($err, $warnings, $state, $waited) = wait_for_import(undef, undef, 5);
is($err, "a volume transfer is still running\n", 'shorter timeout: error');
ok($waited >= 5 && $waited < 5.2, 'shorter timeout: waits until its deadline');

($err) = wait_for_import(undef, undef, undef, { storecfg => {}, vmid => 100 });
is($err, '', 'no import: no error');
is($queries + $pauses, 0, 'no import: nothing to wait for');

done_testing();
