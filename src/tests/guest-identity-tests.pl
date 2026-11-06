#!/usr/bin/perl

use v5.36;

use lib qw(..);

use Test::MockModule;
use Test::More;
use Time::HiRes;

use PVE::JSONSchema;
use PVE::Tools;

use PVE::GuestIdentity;

# records the pending uids that get written, as [$vmid, $uid]
my $recorded = [];

package PVE::TestGuest::VM {
    sub guest_type { return 'VM'; }

    sub record_pending_uid($class, $vmid, $uid) {
        push $recorded->@*, [$vmid, $uid];
    }
}

package PVE::TestGuest::CT {
    use base qw(PVE::TestGuest::VM);

    sub guest_type { return 'CT'; }
}

package main;

subtest 'generation with fixed random bytes and time' => sub {
    my $random_bytes = [];
    my $time_ms = 1_700_000_000_123;

    my $identity_module = Test::MockModule->new('PVE::GuestIdentity');
    $identity_module->redefine(
        __random_bytes => sub {
            my ($len) = @_;
            my $bytes = shift(@$random_bytes) // die "test error: no random bytes left\n";
            die "test error: requested $len random bytes\n" if length($bytes) != $len;
            return $bytes;
        },
        __time_ms => sub { return $time_ms; },
    );

    # each byte gives one character, its lowest 5 bits select it from the lowercase RFC 4648 base32
    # alphabet
    my $vectors = [
        ["\x00" x 20, 'a' x 20],
        ["\xff" x 20, '7' x 20],
        ['0123456789abcdefghij', 'qrstuvwxyzbcdefghijk'],
        [pack('C*', 0 .. 19), 'abcdefghijklmnopqrst'],
        [pack('C*', 12 .. 31), 'mnopqrstuvwxyz234567'],
        [pack('C*', map { $_ | 0xe0 } 0 .. 19), 'abcdefghijklmnopqrst'],
    ];

    for my $vector (@$vectors) {
        my ($bytes, $uid) = @$vector;
        $random_bytes = [$bytes];
        is_deeply(
            PVE::GuestIdentity::new_identity(),
            { uid => $uid, rtime => $time_ms },
            "encodes " . unpack('H*', $bytes),
        );
    }

    # every symbol is as likely at each position, as each of them comes from 8 of the 256 values of
    # the byte at that position
    my $alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
    my $mismatches = 0;
    for my $position (0 .. 19) {
        for my $value (0 .. 255) {
            my $bytes = "\x00" x 20;
            substr($bytes, $position, 1) = chr($value);
            $random_bytes = [$bytes];
            my $expected = 'a' x 20;
            substr($expected, $position, 1) = substr($alphabet, $value % 32, 1);
            $mismatches++ if PVE::GuestIdentity::new_identity()->{uid} ne $expected;
        }
    }
    is($mismatches, 0, 'each character comes from the byte at its position');

    $random_bytes = [];
    is_deeply(
        PVE::GuestIdentity::new_identity('gaytemzugu3doobzmfrg'),
        { uid => 'gaytemzugu3doobzmfrg', rtime => $time_ms },
        'given uid is used',
    );
    eval { PVE::GuestIdentity::new_identity('GAYTEMZUGU3DOOBZMFRG') };
    like($@, qr/invalid guest identity uid/, 'invalid given uid is rejected');
};

subtest 'generation' => sub {
    my $first = PVE::GuestIdentity::new_identity();
    my $second = PVE::GuestIdentity::new_identity();
    like($first->{uid}, qr/^[a-z2-7]{20}\z/, 'uid has the expected format');
    my @uids = map { PVE::GuestIdentity::new_identity()->{uid} } 1 .. 100;
    is_deeply([grep { !m/^[a-z2-7]{20}\z/ } @uids], [], 'uids have 20 characters, no padding');
    isnt($first->{uid}, $second->{uid}, 'uids differ');

    my $before = int(Time::HiRes::time() * 1000);
    my $rtime = PVE::GuestIdentity::new_identity()->{rtime};
    my $after = int(Time::HiRes::time() * 1000) + 1;
    like($rtime, qr/^\d+\z/, 'rtime is an integer');
    ok($rtime >= $before && $rtime <= $after, 'rtime is the current time in milliseconds');
};

subtest 'format properties' => sub {
    my $format = {
        ctime => { type => 'integer', optional => 1 },
        PVE::GuestIdentity::meta_format_properties()->%*,
    };

    is_deeply(
        PVE::JSONSchema::parse_property_string(
            $format,
            'ctime=1700000000,rtime=1700000000123,uid=gaytemzugu3doobzmfrg',
        ),
        { ctime => 1700000000, rtime => 1700000000123, uid => 'gaytemzugu3doobzmfrg' },
        'meta string with identity parses with a merged format',
    );

    for my $invalid (
        'uid=GAYTEMZUGU3DOOBZMFRG',
        'uid=gaytemzugu3doobzmfr',
        'uid=gaytemzugu3doobzmfrga',
        'uid=gaytemzugu3doobzmfr0',
        'uid=' . substr('gaytemzugu3doobzmfrg', 0, 16),
        'rtime=-1',
        'rtime=1.5',
        'rtime=1000000000000000',
    ) {
        eval { PVE::JSONSchema::parse_property_string($format, $invalid) };
        ok($@, "format rejects '$invalid'");
    }

    my $copy = PVE::GuestIdentity::meta_format_properties();
    $copy->{uid}->{pattern} = '.*';
    isnt(
        PVE::GuestIdentity::meta_format_properties()->{uid}->{pattern},
        '.*',
        'callers get their own copy',
    );
};

subtest 'parse identity' => sub {
    my $uid = 'gaytemzugu3doobzmfrg';
    my $tests = [
        [undef, undef, 'no meta'],
        ['', undef, 'empty meta'],
        ['ctime=1700000000', undef, 'meta without identity'],
        [
            "creation-qemu=10.1.2,ctime=1700000000,rtime=123,uid=$uid",
            { uid => $uid, rtime => 123 },
            'identity next to other members',
        ],
        [
            "future=a b,uid=$uid,other,rtime=0",
            { uid => $uid, rtime => 0 },
            'unknown members and odd parts are ignored',
        ],
        ["rtime=123,uid=$uid", { uid => $uid, rtime => 123 }, 'identity only'],
        ["uid=$uid", { uid => $uid, rtime => undef }, 'missing rtime'],
        ["uid=$uid,rtime=12a", { uid => $uid, rtime => undef }, 'invalid rtime'],
        ["uid=$uid,rtime=-5", { uid => $uid, rtime => undef }, 'negative rtime'],
        [
            "uid=$uid,rtime=999999999999999",
            { uid => $uid, rtime => 999999999999999 },
            'maximum rtime',
        ],
        ["uid=$uid,rtime=1000000000000000", { uid => $uid, rtime => undef }, 'too large rtime'],
        [
            "uid=$uid,rtime=\x{0661}\x{0662}",
            { uid => $uid, rtime => undef },
            'non-ASCII digits',
        ],
        ["uid=$uid,rtime=1,rtime=2", { uid => $uid, rtime => undef }, 'duplicate rtime'],
        ['rtime=123', undef, 'rtime without uid'],
        ["uid=$uid,uid=$uid,rtime=1", undef, 'duplicate uid'],
        ['uid=GAYTEMZUGU3DOOBZMFRG,rtime=1', undef, 'uppercase uid'],
        ['uid=gaytemzugu3doobzmfr,rtime=1', undef, 'short uid'],
        ['uid=gaytemzugu3doobzmfrga,rtime=1', undef, 'long uid'],
        ['uid=' . substr($uid, 0, 16) . ',rtime=1', undef, '16-character uid'],
        ['uid=gaytemzugu3doobzmfr1,rtime=1', undef, 'uid outside of the alphabet'],
        ["uid= $uid,rtime=1", undef, 'uid with whitespace'],
        # pmxcfs passes control characters on and replaces invalid UTF-8 with U+FFFD
        ["uid=gaytemzugu\tdoobzmfrg,rtime=1", undef, 'control character in the uid'],
        ["uid=gaytemzugu\x{FFFD}doobzmfrg,rtime=1", undef, 'replacement character in the uid'],
        [
            "ctime=17000\x{1}00000,rtime=1,uid=$uid",
            { uid => $uid, rtime => 1 },
            'control character in another member',
        ],
    ];

    for my $test (@$tests) {
        my ($meta, $expected, $name) = @$test;
        is_deeply(PVE::GuestIdentity::parse_identity($meta), $expected, $name);
    }
};

subtest 'parse identity from raw config' => sub {
    my $uid = 'gaytemzugu3doobzmfrg';
    my $other = 'aaaqeayeaudaocajbifq';
    my $identity = { uid => $uid, rtime => 123 };
    my $tests = [
        ['', undef, 'empty config'],
        ["memory: 512\n", undef, 'no meta'],
        [
            "memory: 512\nmeta: ctime=1,rtime=123,uid=$uid\ncores: 2\n",
            $identity,
            'top-level meta',
        ],
        ["meta:   rtime=123,uid=$uid  \n", $identity, 'surrounding whitespace'],
        ["meta: rtime=1,uid=$other\nmeta: rtime=123,uid=$uid\n", $identity, 'last meta wins'],
        ["meta: future=a b,rtime=123,uid=$uid\n", $identity, 'unknown members'],
        ["meta: rtime=123,uid=$uid\nmeta:\n", $identity, 'meta line without value is ignored'],
        [
            "meta: rtime=123,uid=$uid\nmeta:   \n", undef, 'meta line with only spaces counts',
        ],
        ["#meta: rtime=123,uid=$uid\n", undef, 'description line'],
        ["memory: 512\n\n[PENDING]\nmeta: uid=$uid\n", undef, 'pending section is ignored'],
        [
            "meta: rtime=123,uid=$uid\n\n[snap]\nmeta: rtime=1,uid=$other\n",
            $identity,
            'snapshot section is ignored',
        ],
    ];

    for my $test (@$tests) {
        my ($raw, $expected, $name) = @$test;
        is_deeply(PVE::GuestIdentity::parse_identity_from_raw_config($raw), $expected, $name);
    }
};

subtest 'merge identity' => sub {
    my $identity = { uid => 'gaytemzugu3doobzmfrg', rtime => 1700000000123 };
    my $members = 'rtime=1700000000123,uid=gaytemzugu3doobzmfrg';
    my $tests = [
        [undef, $members, 'no meta'],
        ['', $members, 'empty meta'],
        [
            'creation-qemu=10.1.2,ctime=1700000000',
            "creation-qemu=10.1.2,ctime=1700000000,$members",
            'other members are kept',
        ],
        [
            'ctime=1,rtime=5,uid=aaaaaaaaaaaaaaaaaaaa',
            "ctime=1,$members",
            'existing identity is replaced',
        ],
        [
            'uid=bogus,zz-future=x,rtime=1,uid=aaaaaaaaaaaaaaaaaaaa,ctime=1',
            "ctime=1,$members,zz-future=x",
            'invalid and duplicate identity members are dropped, unknown members kept',
        ],
        ['plain,ctime=1', "plain,ctime=1,$members", 'parts without key stay first'],
    ];

    for my $test (@$tests) {
        my ($meta, $expected, $name) = @$test;
        my $merged = PVE::GuestIdentity::merge_identity($meta, $identity);
        is($merged, $expected, $name);
        is_deeply(PVE::GuestIdentity::parse_identity($merged), $identity, "$name, parses back");
    }

    for my $invalid (
        { uid => 'GAYTEMZUGU3DOOBZMFRG', rtime => 1 },
        { uid => 'gaytemzugu3doobzmfrg', rtime => undef },
        { uid => 'gaytemzugu3doobzmfrg', rtime => 'now' },
        { uid => 'gaytemzugu3doobzmfrg', rtime => '1000000000000000' },
        { uid => 'gaytemzugu3doobzmfrg,ctime=1', rtime => 1 },
        { rtime => 1 },
    ) {
        eval { PVE::GuestIdentity::merge_identity('ctime=1', $invalid) };
        ok($@, "invalid identity is rejected");
    }
};

subtest 'node version check' => sub {
    my $min = PVE::GuestIdentity::MIN_PVE_MANAGER_VERSION;
    like($min, qr/^[0-9]+\.[0-9]+\.[0-9]+\z/, 'minimum version is a version string');
    my ($major, $minor, $release) = split(/\./, $min);

    my $versions = {
        current => "$major.$minor.$release",
        newer => "$major." . ($minor + 1) . ".0",
        older => "$major.$minor." . ($release - 1),
        invalid => 'invalid',
    };

    my $cluster_module = Test::MockModule->new('PVE::Cluster');
    $cluster_module->mock(
        get_node_pvecfg_version => sub {
            my ($node) = @_;
            die "malformed version info\n" if $node eq 'malformed';
            return $versions->{$node};
        },
        node_pvecfg_version_at_least => sub {
            my ($node, @min) = @_;
            my $version = PVE::Cluster::get_node_pvecfg_version($node);
            return $version && PVE::Tools::pvecfg_min_version($version, @min);
        },
    );

    for my $node (qw(current newer)) {
        eval { PVE::GuestIdentity::assert_node_supports_identity($node) };
        is($@, '', "node with version '$versions->{$node}' is supported");
        my $unsupported = PVE::GuestIdentity::node_identity_unsupported($node);
        is($unsupported, undef, "no reason for '$node'");
    }

    for my $node (qw(older invalid missing malformed)) {
        eval { PVE::GuestIdentity::assert_node_supports_identity($node) };
        like($@, qr/node '$node'/, "node '$node' is refused");
    }

    my $schema = PVE::GuestIdentity::node_identity_unsupported_schema();
    isnt(
        $schema,
        PVE::GuestIdentity::node_identity_unsupported_schema(),
        'schema is a new copy',
    );
    for my $node (qw(older invalid missing malformed)) {
        my $unsupported = PVE::GuestIdentity::node_identity_unsupported($node);
        eval { PVE::JSONSchema::validate($unsupported, $schema) };
        is($@, '', "reason for '$node' matches the schema");
    }

    for my $node (qw(older invalid)) {
        is_deeply(
            PVE::GuestIdentity::node_identity_unsupported($node),
            { version => $versions->{$node}, 'required-version' => $min },
            "reason for '$node' has both versions",
        );
        eval { PVE::GuestIdentity::assert_node_supports_identity($node) };
        is(
            $@,
            "node '$node' runs Proxmox VE $versions->{$node}, keeping the guest identity requires"
                . " $min or newer - upgrade the node first\n",
            "refusal of '$node' names both versions",
        );
    }

    for my $node (qw(missing malformed)) {
        is_deeply(
            PVE::GuestIdentity::node_identity_unsupported($node),
            { 'required-version' => $min },
            "reason for '$node' has only the required version",
        );
        eval { PVE::GuestIdentity::assert_node_supports_identity($node) };
        is(
            $@,
            "node '$node' does not report its Proxmox VE version, so it is unknown whether the"
                . " node keeps the guest identity\n",
            "refusal of '$node' says why",
        );
    }
};

subtest 'pending uid' => sub {
    my $uid = 'gaytemzugu3doobzmfrg';
    my $other = 'aaaaaaaaaaaaaaaaaaaa';

    is(PVE::GuestIdentity::get_pending_uid({}), undef, 'none without pending section');
    is(PVE::GuestIdentity::get_pending_uid({ pending => { memory => 1 } }), undef, 'none');
    is(
        PVE::GuestIdentity::get_pending_uid({ pending => { meta => 'uid=' . uc($uid) } }),
        undef,
        'invalid pending uid is none',
    );
    is(
        PVE::GuestIdentity::get_pending_uid({ pending => { meta => "ctime=1,uid=$uid" } }),
        $uid,
        'other members are ignored',
    );

    my $conf = { meta => "rtime=1,uid=$other", pending => { memory => 1 } };
    PVE::GuestIdentity::set_pending_uid($conf, $uid);
    is_deeply(
        $conf,
        { meta => "rtime=1,uid=$other", pending => { memory => 1, meta => "uid=$uid" } },
        'set: only the uid member, other pending changes are kept',
    );
    is(PVE::GuestIdentity::get_pending_uid($conf), $uid, 'set: read back');

    PVE::GuestIdentity::set_pending_uid($conf, undef);
    is_deeply(
        $conf,
        { meta => "rtime=1,uid=$other", pending => { memory => 1 } },
        'remove: other pending changes are kept',
    );
    $conf = {};
    PVE::GuestIdentity::set_pending_uid($conf, undef);
    is_deeply($conf, {}, 'remove without pending section changes nothing');

    eval { PVE::GuestIdentity::set_pending_uid({}, 'GAYTEMZUGU3DOOBZMFRG') };
    like($@, qr/invalid guest identity uid/, 'invalid uid is refused');
};

subtest 'prepare restore' => sub {
    my $uid = 'gaytemzugu3doobzmfrg';
    my $other = 'aaaaaaaaaaaaaaaaaaaa';

    my $previous = { uid => $other, rtime => 1 };
    my $without_identity = { previous => undef, 'previous-pending-uid' => undef };
    my $with_identity = { previous => $previous, 'previous-pending-uid' => undef };
    my $leftover = { previous => $previous, 'previous-pending-uid' => $uid };
    my $other_leftover = { previous => $previous, 'previous-pending-uid' => 'b' x 20 };

    # reservation, uid of the backup, 'allow-identity-mismatch', then what is expected: whether
    # the restore is refused or logs that it ignores the uid of the backup, and the pending uid
    my $tests = [
        [$without_identity, $uid, 0, undef, $uid, 'target without identity'],
        [$without_identity, undef, 0, undef, undef, 'backup without uid'],
        [undef, $uid, 0, undef, undef, 'no reservation'],
        [$with_identity, $other, 0, undef, undef, 'backup of the target'],
        [$with_identity, $uid, 0, 'refused', undef, 'backup of another guest'],
        [$with_identity, $uid, 1, 'ignored', undef, 'backup of another guest, allowed'],
        [$leftover, $uid, 0, undef, $uid, 'leftover of the backup'],
        [$leftover, $other, 0, undef, undef, 'leftover of the backup, backup of the target'],
        [$other_leftover, $uid, 0, 'refused', undef, 'leftover of another backup'],
        [$other_leftover, $uid, 1, 'ignored', undef, 'leftover of another backup, allowed'],
    ];

    for my $class (qw(PVE::TestGuest::VM PVE::TestGuest::CT)) {
        my $type = $class->guest_type();
        my $messages = {
            refused =>
                "backup belongs to another guest: its uid '$uid' differs from uid '$other' of"
                . " the existing $type 100 - use 'allow-identity-mismatch' to overwrite the $type"
                . " anyway\n",
            ignored => "guest identity: ignoring backup uid $uid, $type 100 keeps uid $other\n",
        };

        for my $test (@$tests) {
            my ($reservation, $backup_uid, $allow_mismatch, $outcome, $pending_uid, $name) =
                @$test;
            $recorded = [];

            my $output = '';
            open(my $fh, '>', \$output) or die "unable to capture output - $!\n";
            my $previous_fh = select($fh);
            my $res = eval {
                PVE::GuestIdentity::prepare_restore(
                    $class, 100, $reservation, $backup_uid, $allow_mismatch,
                );
            };
            my $err = $@;
            select($previous_fh);
            close($fh);

            is_deeply(
                [$err, $output, $res, $recorded],
                [
                    ($outcome // '') eq 'refused' ? $messages->{refused} : '',
                    ($outcome // '') eq 'ignored' ? $messages->{ignored} : '',
                    $pending_uid,
                    defined($pending_uid) ? [[100, $pending_uid]] : [],
                ],
                "$type: $name",
            );
        }
    }

    my $option = PVE::JSONSchema::get_standard_option('pve-guest-allow-identity-mismatch');
    is($option->{type}, 'boolean', 'the override is a standard option');
};

done_testing();
