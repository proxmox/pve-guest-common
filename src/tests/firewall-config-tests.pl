#!/usr/bin/perl

use v5.36;

use lib qw(..);

use File::Temp qw(tempdir);
use Test::More;

use PVE::GuestHelpers;
use PVE::Tools;

my $tmpdir = tempdir('firewall-config-XXXXXX', DIR => '.', CLEANUP => 1);
my $dir = $PVE::GuestHelpers::firewall_config_dir = "$tmpdir/firewall";

my sub file_of($vmid) {
    return -e "$dir/$vmid.fw" ? PVE::Tools::file_get_contents("$dir/$vmid.fw") : undef;
}

ok(!defined(PVE::GuestHelpers::get_firewall_config_raw(100)), 'no config: undef');
PVE::GuestHelpers::set_firewall_config_raw(100, undef);
ok(!-e $dir, 'no config: removing it again changes nothing');

my $raw = "[OPTIONS]\n\nenable: 1\n\n[RULES]\n\nIN SSH(ACCEPT) -i net0\n";
PVE::GuestHelpers::set_firewall_config_raw(100, $raw);
is(file_of(100), $raw, 'config is written as given');
is(PVE::GuestHelpers::get_firewall_config_raw(100), $raw, 'config is read as stored');
ok(!defined(PVE::GuestHelpers::get_firewall_config_raw(101)), 'other guest: undef');

# what a failed operation does: put back what was there before it replaced the config
my $before = PVE::GuestHelpers::get_firewall_config_raw(100);
PVE::GuestHelpers::set_firewall_config_raw(100, "[OPTIONS]\n\nenable: 0\n");
PVE::GuestHelpers::set_firewall_config_raw(100, $before);
is(file_of(100), $raw, 'replaced config: put back');

$before = PVE::GuestHelpers::get_firewall_config_raw(101);
PVE::GuestHelpers::set_firewall_config_raw(101, "[OPTIONS]\n\nenable: 0\n");
PVE::GuestHelpers::set_firewall_config_raw(101, $before);
ok(!-e "$dir/101.fw", 'config that did not exist: removed again');
is(file_of(100), $raw, 'config that did not exist: other guest is unchanged');

PVE::GuestHelpers::set_firewall_config_raw(102, '');
is(PVE::GuestHelpers::get_firewall_config_raw(102), '', 'empty config: not the same as none');

mkdir "$dir/103.fw";
eval { PVE::GuestHelpers::get_firewall_config_raw(103) };
like($@, qr/^unable to read file '\Q$dir\E\/103.fw' - /, 'read error: not taken for no config');
eval { PVE::GuestHelpers::set_firewall_config_raw(103, undef) };
like($@, qr/^unable to remove '\Q$dir\E\/103.fw' - /, 'error on removal: reported');

done_testing();
