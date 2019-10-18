#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use Test::More;
#use Test::MockModule;

use PVE::AbstractConfig;


# tests for different top level method implementations of AbstractConfig
# tests need to specify the method, the parameter and expected result
# for neatly doing more tests per single method you can specifiy a subtests
# array, which then only has params and expected result

# note that the indentaion level below is "wrong" by design
my $tests = [
{
    method => 'parse_pending_delete',
    subtests => [
	{
	    params => [ "memory,cpu" ],
	    expect => {
		cpu => { force => 0, },
		memory => { force => 0, },
	    },
	},
	{
	    params => [ "memory;cpu,!mp0" ],
	    expect => {
		cpu => { force => 0, },
		memory => { force => 0, },
		mp0 => { force => 1, },
	    },
	},
	{
	    params => [ "  memory ; cpu, !mp0, !mp1" ],
	    expect => { # can separate with comma, semicolon, spaces
		cpu => { force => 0, },
		memory => { force => 0, },
		mp0 => { force => 1, },
		mp1 => { force => 1, },
	    },
	},
	{
	    params => [ "!!memory" ],
	    expect => { # we have no double negation, only simple stuff
		'!memory' => { force => 1, },
	    },
	},
	{
	    params => [ " mem ory" ],
	    expect => { # we do not support keys with spaces, seens as two different ones
		'mem' => { force => 0, },
		'ory' => { force => 0, },
	    },
	},
    ]
},
]; # tests definition end


sub do_test($$;$) {
    my ($method, $test, $name) = @_;

    fail("incomplete test, params or expected missing")
	if !exists $test->{params} || !exists $test->{expect};

    my ($params, $expect) = $test->@{qw(params expect)};

    my $res = eval { PVE::AbstractConfig->$method(@$params) };
    if (my $err = $@) {
	is ($err, $expect, $name);
    } else {
	is_deeply($res, $expect, $name);
    }
}

for my $test (@$tests) {
    my $method = $test->{method} or fail("missing AbstractConfig method to test") and next;

    my $name = $test->{name} // $method;

    if (defined(my $subtests = $test->{subtests})) {
	subtest $name => sub {
	    for my $subtest (@$subtests) {
		do_test($method, $subtest);
	    }
	}
    } else {
	do_test($method, $test, $name);
    }
    #my $expected = $test->{expect};
}

done_testing();
