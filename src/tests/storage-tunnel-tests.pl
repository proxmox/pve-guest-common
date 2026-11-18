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

done_testing();
