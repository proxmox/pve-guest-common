#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use Test::More;
#use Test::MockModule;

use PVE::AbstractConfig;


# tests for different top level method implementations of AbstractConfig
# tests need to specify the method, the parameter and expected result
# for neatly doing more tests per single method you can specify a subtests
# array, which then only has params and expected result
# sometimes the return value is less interesting to check than a parameter
# reference, so one can use "map_expect_to_param_id" to tell the test system to
# use that as expected result.

# note that the indentation level below is "wrong" by design
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
{
    method => 'print_pending_delete',
    subtests => [
	{
	    params => [{
		cpu => { force => 0, },
		memory => { force => 0, },
	    }],
	    expect => "cpu,memory",
	},
	{
	    params => [{ # we have no double negation, only simple stuff
		'!memory' => { force => 1, },
	    }],
	    expect => "!!memory",
	},
    ]
},
{
    method => 'add_to_pending_delete', # $conf, $key, $force
    subtests => [
	{ # simple test addition to of a pending deletion to the empty config
	    params => [ {}, 'memory', ],
	    expect => { pending => { delete => 'memory', }, },
,
	},
	{
	    params => [ { pending => { delete => 'cpu', }, }, 'memory', 1 ],
	    expect => { pending => { delete => 'cpu,!memory', }, },
,
	},
	{
	    params => [ { pending => { delete => 'cpu', }, }, 'cpu', 1 ],
	    expect => { pending => { delete => '!cpu', }, },
	},
	{
	    params => [ { pending => { delete => 'cpu', }, }, 'cpu', ],
	    expect => { pending => { delete => 'cpu', }, },
	},
    ]
},
{
    method => 'remove_from_pending_delete', # $conf, $key
    subtests => [
	{
	    params => [ { pending => { delete => 'memory', } }, 'memory' ],
	    expect => { pending => {} },
	},
	{
	    params => [ { pending => { delete => 'cpu,!memory', } }, 'memory' ],
	    expect => { pending => { delete => 'cpu' } },
	},
	{
	    params => [ { pending => { delete => 'cpu', } }, 'memory' ],
	    expect => { pending => { delete => 'cpu' } },
	},
    ]
},
{
    method => 'cleanup_pending', # $conf
    subtests => [
	{ # want to delete opt which is not in config? -> all done, cleanup!
	    params => [{
		pending => { delete => 'memory', }
	    }],
	    map_expect_to_param_id => 0,
	    expect => { pending => {} },
	},
	{ # should do nothing, delete is pending and memory is set after all
	    params => [{
		memory => 128,
		pending => { delete => 'memory', }
	    }],
	    map_expect_to_param_id => 0,
	    expect => {
		memory => 128,
		pending => { delete => 'memory', }
	    },
	},
	{ # the pending change is the same as the currents config value, cleanup pending!
	    params => [{
		memory => 128,
		pending => { memory => 128, }
	    }],
	    map_expect_to_param_id => 0,
	    expect => {
		memory => 128,
		pending => {}
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

    if (defined(my $param_id = $test->{map_expect_to_param_id})) {
	# it's a /cool/ hack, sometimes we have the interesting result in
	# "call-by-reference" param, and the return value is just some "I did
	# something" or plain undef value. So allow to map the result to one of
	# the parameters
	$res = $params->[$param_id];
    }

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
