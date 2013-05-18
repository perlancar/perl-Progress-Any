#!/usr/bin/perl

use 5.010;
use strict;
use warnings;

use Test::More 0.98;
use Progress::Any;

%Progress::Any::indicators = ();

subtest "get_indicator" => sub {
    Progress::Any->get_indicator(task=>"a.b", target=>10);
    Progress::Any->get_indicator(task=>"a.b.d", target=>7, pos=>2);
    Progress::Any->get_indicator(task=>"a.c", target=>5, pos=>1);

    is($Progress::Any::indicators{"a"}{target}, 0, "a's target");
    is($Progress::Any::indicators{"a"}{ctarget}, 22, "a's ctarget");
    is($Progress::Any::indicators{"a"}{pos}, 3, "a's pos");
    is($Progress::Any::indicators{"a.b"}{ctarget}, 7, "a.b's ctarget");
    is($Progress::Any::indicators{"a.b"}{pos}, 2, "a.b's pos");

    Progress::Any->get_indicator(task=>"a.b.e");

    ok(!defined($Progress::Any::indicators{"a"}{ctarget}), "a's ctarget becomes undefined");
    ok(!defined($Progress::Any::indicators{"a.b"}{ctarget}), "a.b's ctarget becomes undefined");
};

subtest "target" => sub {
    my $p = Progress::Any->get_indicator(task=>"a.b.e");

    # stays undef
    $p->target(undef);

    ok(!defined($Progress::Any::indicators{"a"}{ctarget}), "a's ctarget stays undefined");
    ok(!defined($Progress::Any::indicators{"a.b"}{ctarget}), "a.b's ctarget stays undefined");

    # undef becomes defined
    $p->target(3);

    is($Progress::Any::indicators{"a"}{ctarget}, 25, "a's ctarget becomes defined");
    is($Progress::Any::indicators{"a.b"}{ctarget}, 10, "a.b's ctarget becomes defined");

    # defined stays defined
    $p->target(5);

    is($Progress::Any::indicators{"a"}{ctarget}, 27, "a's ctarget updated");
    is($Progress::Any::indicators{"a.b"}{ctarget}, 12, "a.b's ctarget updated");

    # defined becomes undef
    $p->target(undef);

    ok(!defined($Progress::Any::indicators{"a"}{ctarget}), "a's ctarget becomes undefined");
    ok(!defined($Progress::Any::indicators{"a.b"}{ctarget}), "a.b's ctarget becomes undefined");
};

subtest "pos" => sub {
    my $p = Progress::Any->get_indicator(task=>"a.b.e");

    $p->pos(1);

    is($Progress::Any::indicators{"a"}{pos}, 4, "a's pos updated");
    is($Progress::Any::indicators{"a.b"}{pos}, 3, "a.b's pos updated");

    $p->pos(3);

    is($Progress::Any::indicators{"a"}{pos}, 6, "a's pos updated (2)");
    is($Progress::Any::indicators{"a.b"}{pos}, 5, "a.b's pos updated (2)");
};

#subtest "update" => sub {
#};

#subtest "fill_template" => sub {
#};

DONE_TESTING:
done_testing;
