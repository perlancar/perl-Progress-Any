#!/usr/bin/perl

use 5.010;
use strict;
use warnings;

use Test::More 0.98;
use Progress::Any;

%Progress::Any::indicators = ();

subtest "get_indicator, pos, target, total_target" => sub {
    my $p_ab = Progress::Any->get_indicator(task=>"a.b", target=>10);
    is($p_ab->pos, 0, "a.b's pos");
    is($p_ab->target, 10, "a.b's target");
    is($p_ab->total_target, 10, "a.b's total target");

    my $p_a  = Progress::Any->get_indicator(task=>"a");
    is($p_a->pos, 0, "a's target");
    is($p_a->target, 0, "a's target");
    is($p_a->total_target, 10, "a's total target");

    my $p_abd = Progress::Any->get_indicator(task=>"a.b.d", target=>7, pos=>2);
    is($p_abd->pos, 2, "a.b.d's pos");
    is($p_abd->target, 7, "a.b.d's target");
    is($p_abd->total_target, 7, "a.b.d's total target");
    is($p_ab->pos, 2, "a.b's pos");
    is($p_ab->total_target, 17, "a.b's total target");
    is($p_a->total_target, 17, "a's total target");

    my $p_ac = Progress::Any->get_indicator(task=>"a.c", target=>5, pos=>1);
    is($p_ac->pos, 1, "a.c's pos");
    is($p_ac->target, 5, "a.c's target");
    is($p_ac->total_target, 5, "a.c's total target");
    is($p_a->pos, 3, "a's pos");
    is($p_a->total_target, 22, "a's total target");

    my $p_abe = Progress::Any->get_indicator(task=>"a.b.e");
    is($p_abe->pos, 0, "a.e's pos");
    ok(!defined($p_abe->target), "a.e's target is undef");
    ok(!defined($p_ab->total_target), "a.b's total target becomes undef");
    ok(!defined($p_a->total_target), "a's total target becomes undef");
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
