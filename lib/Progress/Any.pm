package Progress::Any;

use 5.010001;
use strict;
use warnings;

use Time::Duration qw();
use Time::HiRes qw(time);

# VERSION

sub import {
    my ($self, @args) = @_;
    my $caller = caller();
    for (@args) {
        if ($_ eq '$progress') {
            my $progress = $self->get_indicator(task => '');
            {
                no strict 'refs';
                my $v = "$caller\::progress";
                *$v = \$progress;
            }
        } else {
            die "Unknown import argument: $_";
        }
    }
}

our %indicators; # key = task name
our %outputs;    # key = task name, value = [$outputobj, ...]
our $mtime;

# internal attributes:
# - _st_target (float) = sum of all subtasks' target
# - _st_pos (float*) = sum of all subtasks' pos
# - _elapsed (float*)
# - _remaining (float)
# - _st_remaining (float) = sum of all subtasks' remaining

# return 1 if created, 0 if already created/initialized
sub _init_indicator {
    my ($class, $task, $ctime) = @_;

    #say "D: _init_indicator($task)";

    # prevent double initialization
    return $indicators{$task} if $indicators{$task};

    $ctime //= time();

    my $progress = bless({
        task       => $task,
        title      => $task,
        target     => 0,
        pos        => 0,
        ctime      => $ctime,
        state      => 'stopped',
        pctcomp    => 0,

        _elapsed      => 0,
        _remaining    => 0,
        _st_target    => 0,
        _st_pos       => 0,
        _st_remaining => 0,
    }, $class);
    $indicators{$task} = $progress;

    # if we create an indicator named a.b.c, we must also create a.b, a, and ''.
    if ($task =~ s/\.?\w+\z//) {
        #say "D: task -> $task";
        # make ctime of parents the same, parents must be "born" earlier or at
        # least at the same time as children
        $class->_init_indicator($task, $ctime);
    }

    $progress->_update(-calc_all=>1);
    $progress;
}

sub get_indicator {
    my ($class, %args) = @_;

    my %oargs = %args;

    my $task   = delete($args{task});
    if (!defined($task)) {
        my @caller = caller(0);
        #say "D:caller=".join(",",map{$_//""} @caller);
        $task = $caller[0] eq '(eval)' ? 'main' : $caller[0];
        $task =~ s/::/./g;
        $task =~ s/[^.\w]+/_/g;
    }
    die "Invalid task syntax '$task', please only use dotted words"
        unless $task =~ /\A(?:\w+(\.\w+)*)?\z/;

    my %uargs;

    my $p = $class->_init_indicator($task);
    for my $an (qw/title target pos remaining state/) {
        if (exists $args{$an}) {
            $uargs{$an} = delete($args{$an});
        }
    }
    die "Unknown argument(s) to get_indicator(): ".join(", ", keys(%args))
        if keys(%args);
    $p->_update(%uargs) if keys %uargs;

    $p;
}

my %attrs = (
    title     => {is => 'rw'},
    target    => {is => 'rw'},
    pos       => {is => 'rw'},
    remaining => {is => 'rw', manual=>1}, # calc
    state     => {is => 'rw'},
    pctcomp   => {is => 'ro'}, # calc
    ctime     => {is => 'ro'},
    elapsed   => {is => 'ro', manual=>1}, # calc
);

# create attribute methods
for my $an (keys %attrs) {
    next if $attrs{$an}{manual};
    my $code;
    if ($attrs{$an}{is} eq 'rw') {
        $code = sub {
            my $self = shift;
            if (@_) {
                $self->_update($an => shift);
            }
            $self->{$an};
        };
    } else {
        $code = sub {
            my $self = shift;
            die "Can't set value, $an is an ro attribute" if @_;
            $self->{$an};
        };
    }
    no strict 'refs';
    *{$an} = $code;
}

sub elapsed {
    my $self = shift;

    if ($self->{state} eq 'started') {
        return $self->{_elapsed} + (time()-$mtime);
    } else {
        return $self->{_elapsed};
    }
}

sub remaining {
    my $self = shift;

    if (@_) {
        $self->_update(remaining => shift);
        return $self;
    }

    my $r = $self->{_remaining};
    return undef unless defined($r);

    if ($self->{state} eq 'started') {
        my $res = $r + ($mtime - time());
        return $res > 0 ? $res : 0;
    } else {
        return $r;
    }
}

sub remaining_inclusive {
    my $self = shift;

    my $r = $self->remaining;
    my $str = $self->{_st_remaining};
    return undef unless defined($r) && defined($str);
    $r + $str;
}

sub target_inclusive {
    my $self = shift;

    my $t = $self->{target};
    my $stt = $self->{_st_target};
    return undef unless defined($t) && defined($stt);
    $t + $stt;
}

sub pos_inclusive {
    my $self = shift;

    $self->{pos} + $self->{_st_pos};
}

# the routine to update rw attributes and recalculate calculated attributes
# (including those of parents). pass it the attributes you want to change and it
# will do validation and updating and recalculation.
sub _update {
    my ($self, %args) = @_;

    # no need to check for unknown arg in %args, it's an internal method anyway

    my $task = $self->{task};
    use Data::Dump; print "D: _update($task) "; dd \%args;
    my %flags;

    my @parents;
    {
        my $t = $task;
        while (1) {
            last unless $t =~ s/\.\w+\z//;
            push @parents, $t;
        }
        push @parents, '';
    }

  SET_TITLE:
    {
        last unless exists $args{title};
        my $val = $args{title};
        die "Invalid value for title, must be defined"
            unless defined($val);
        $self->{title} = $val;
    }

  SET_POS:
    my $old_pos = $self->{pos};
    {
        last unless exists $args{pos};
        my $val = $args{pos};
        die "Invalid value for pos, must be a positive number"
            unless defined($val) && $val >= 0;
        last if $val == $old_pos;

        # ensure that pos does not exceed target
        if (defined($self->{target}) && $val > $self->{target}) {
            $val = $self->{target};
        }

        $flags{adjust_parents_st_pos}++;
        $flags{adjust_parents_st_remaining}++;
        $flags{calc_pctcomp_and_remaining_for}{$task} = 1;
        $self->{pos} = $val;
    }

  SET_TARGET:
    my $old_target = $self->{target};
    {
        last unless exists $args{target};
        my $val = $args{target};
        die "Invalid value for target, must be a positive number or undef"
            unless !defined($val) || $val >= 0;
        if (defined($val) && defined($old_target)) {
            # stay defined
            last if $val == $old_target;

            # ensure that pos does not exceed target
            if ($self->{pos} > $val) {
                $self->{pos} = $val;
                $flags{adjust_parents_st_pos}++;
                $flags{adjust_parents_st_remaining}++;
            }

            $flags{adjust_parents_st_target}++;
            $flags{calc_pctcomp_and_remaining_for}{$task} = 1;
            $flags{calc_pctcomp_and_remaining_for}{$_} = 1 for @parents;
        } elsif (!defined($val) && defined($old_target)) {
            # from defined becomes undef
            undef $self->{pctcomp};
            undef $self->{_remaining};
            for (@parents) {
                undef $indicators{$_}{pctcomp};
                undef $indicators{$_}{_remaining};
                undef $indicators{$_}{_st_target};
                undef $indicators{$_}{_st_remaining};
            }
        } elsif (defined($val) && !defined($old_target)) {
            # from undef becomes defined

            # ensure that pos does not exceed target
            if ($self->{pos} > $val) {
                $self->{pos} = $val;
                $flags{adjust_parents_st_pos}++;
                $flags{adjust_parents_st_remaining}++;
            }

            for (@parents) {
                $flags{calc_st_target_for}{$_} = 1;
                $flags{calc_pctcomp_and_remaining_for}{$_} = 1;
            }
        } else {
            # stay undefined, do nothing
            last;
        }
        $self->{target} = $val;
    }

  ADJUST_PARENTS_ST_POS:
    {
        last unless $args{-calc_all} || $flags{adjust_parents_st_pos};
        my $diff = $self->{pos} - $old_pos;
        for (@parents) {
            $indicators{$_}{_st_pos} += $diff;
            $flags{calc_pctcomp_and_remaining_for}{$_} = 1;
        }
    }

  ADJUST_PARENTS_ST_TARGET:
    {
        last unless $args{-calc_all} || $flags{adjust_parents_st_target};
        my $diff = $self->{target} - $old_target;
        for (@parents) {
            last unless defined $indicators{$_}{_st_target};
            $indicators{$_}{_st_target} += $diff;
            $flags{calc_pctcomp_and_remaining_for}{$_} = 1;
        }
    }

  CALC_PCTCOMP_AND_REMAINING_FOR:
    {
        for my $t (sort {length($b) <=> length($a)} # children before parent
                       keys %{$flags{calc_pctcomp_and_remaining_for}}) {
            #say "D: calc pctcomp for $t";
            my $p = $indicators{$t};
            my $tot_pos = $p->pos_inclusive;
            my $tot_target = $p->target_inclusive;
            if (!defined($tot_target)) {
                $p->{pctcomp} = undef;
            } elsif ($tot_target == 0) {
                $p->{pctcomp}    = $p->{state} eq 'finished' ? 100 : 0;
                $p->{_remaining} = 0 if $p->{state} eq 'finished';
            } else {
                $p->{pctcomp}    = $tot_pos / $tot_target * 100;
                if ($self->{pos} && defined($self->{target})) {
                    my $e = $p->elapsed;
                    $p->{_remaining} =
                        ($self->{target}-$self->{pos}) / $self->{pos} * $e;
                }
            }
        }
    }

  SET_REMAINING:
    my $old_remaining = $self->{_remaining};
    {
        last unless exists $args{_remaining};
        my $val = $args{remaining};
        die "Invalid value for remaining, must be a positive number or undef"
            unless !defined($val) || $val >= 0;
        $self->{_remaining} = $val;
        $flags{adjust_parents_st_remaining}++;
    }

  ADJUST_PARENTS_ST_REMAINING:
    {
        last unless $args{-calc_all} || $flags{adjust_parents_st_remaining};
        for my $t (@parents) {
            my $p = $indicators{$t};
            if (!defined($p->{_st_remaining}) || !defined($old_remaining)) {
                # skip
            } elsif (!defined($self->{_remaining})) {
                undef $p->{_st_remaining};
            } else {
                say "TMP: task=$task, diff=", ($self->{_remaining} - $old_remaining);
                $p->{_st_remaining} += $self->{_remaining} - $old_remaining;
            }
        }
    }

  UPDATE_ELAPSED:
    my $now = time();
    {
        last unless $mtime;
        my $diff = $now - $mtime;
        for my $t (keys %indicators) {
            my $p = $indicators{$t};
            next unless $p->{state} eq 'started';
            $p->{_elapsed} += $diff;
        }
    }

  SET_STATE:
    my $old_state = $self->{state};
    {
        if (exists $args{state}) {
            my $val = $args{state} // 'started';
            die "Invalid value for state, must be stopped/started/finished"
                unless $val =~ /\A(?:stopped|started|finished)\z/;
            last if $self->{state} eq $val;
            $self->{state} = $val;
            # automatically start parents
            if ($val eq 'started') {
                for my $t (@parents) {
                    my $p = $indicators{$t};
                    $p->{state} = 'started' if $p->{state} eq 'stopped';
                }
            }
        }
    }

  DONE:
    $mtime = $now;

    #use Data::Dump; print "after update: "; dd $self;
    return;
}

sub update {
    my ($self, %args) = @_;

    my $pos   = delete($args{pos}) // $self->{pos} + 1;
    my $state = delete($args{state}) // 'started';
    $self->_update(pos => $pos, state => $state);

    my $message  = delete($args{message});
    my $level    = delete($args{level});
    die "Unknown argument(s) to update(): ".join(", ", keys(%args))
        if keys(%args);

    my $now = time();

    # find output(s) and call it
    {
        my $task = $self->{task};
        while (1) {
            if ($outputs{$task}) {
                for my $output (@{ $outputs{$task} }) {
                    $output->update(
                        indicator => $indicators{$task},
                        message   => $message,
                        level     => $level,
                        time      => $now,
                    );
                }
            }
            last unless $task =~ s/\.?\w+\z//;
        }
    }
}

sub start {
    my $self = shift;
    $self->_update(state => 'started');
}

sub stop {
    my $self = shift;
    $self->_update(state => 'stopped');
}

sub finish {
    my ($self, %args) = @_;
    $self->update(pos=>$self->{target}, state=>'finished', %args);
}

# - currently used letters: emnPpRrTt%
# - currently used by Output::TermProgressBarColor: bB
# - letters that can be used later: c (ctime?), s (last start time?), S (last
#   stop time? state?)
sub fill_template {
    my ($self, $template, %args) = @_;

    state $re = qr{( # all=1
                       %
                       ( #width=2
                           -?\d+ )?
                       ( #dot=3
                           \.?)
                       ( #prec=4
                           \d+)?
                       ( #conv=5
                           [taeEpcCm%])
                   )}x;
    state $sub = sub {
        my %args = @_;

        my ($all, $width, $dot, $prec, $conv) = ($1, $2, $3, $4, $5);

        my $p = $args{indicator};

        my ($fmt, $sconv, $data);
        if ($conv eq 't') {
            $data = $p->{task};
        } elsif ($conv eq 'a') {
            $data = Time::Duration::concise(Time::Duration::duration(
                $args{time} - $p->{ctime}));
        } elsif ($conv =~ /[eEpC]/o) {
            my $tot = $p->_total_target;
            $width //= 3 if $conv eq 'p';

            if (!defined($tot)) {
                if ($conv eq 'E') {
                    # to prevent duration() produces "just now"
                    my $tot = $tot || 1;

                    $data = Time::Duration::concise(
                        Time::Duration::duration($tot));
                    $data = "$data elapsed"; # XXX localize
                } else {
                    # can't estimate
                    $data = '?';
                }
            } else {
                if ($conv eq 'e' || $conv eq 'E') {
                    my $totinc = 0;
                    my $totelapsed = 0;
                    my $eta;
                    my $rest = $tot - $self->{pos};
                    if ($rest <= 0) {
                        $eta = 0;
                    } else {
                        # first calculate by moving average
                        for (0..@{ $self->{incs} }-1) {
                            $totinc     += $self->{incs}[$_];
                            $totelapsed += $self->{elapseds}[$_];
                        }
                        if ($totinc == 0) {
                            # if not moving at all recently, calculate using
                            # total average
                            if ($self->{pos} > 0) {
                                $totinc     = $self->{pos};
                                $totelapsed = $args{time} - $self->{ctime};
                            }
                        }
                        if ($totinc > 0) {
                            $eta = $totelapsed * $rest/$totinc;
                            #say "D: AVG: totinc=$totinc, totelapsed=$totelapsed, eta=$eta";
                        }
                    }
                    if (defined $eta) {
                        # to prevent duration() produces "just now"
                        $eta = 1 if $eta < 1;

                        $data = Time::Duration::concise(
                            Time::Duration::duration($eta));
                        if ($conv eq 'E') {
                            $data = "$data left"; # XXX localize
                        }
                    } else {
                        if ($conv eq 'E') {
                            # to prevent duration() produces "just now"
                            my $totelapsed = $totelapsed || 1;

                            $data = Time::Duration::concise(
                                Time::Duration::duration($totelapsed));
                            $data = "$data elapsed"; # XXX localize
                        } else {
                            $data = '?';
                        }
                    }
                } elsif ($conv eq 'p' || $conv eq 'C') {
                    $sconv = 'f';
                    $dot = '.';
                    $prec //= 0;
                    if ($conv eq 'p') {
                        $data = $p->{pos} / $tot * 100.0;
                    } else {
                        $data = $tot;
                    }
                }
            }
        } elsif ($conv eq 'c') {
            $data = $p->{pos};
            $sconv = 'f';
            $dot = '.';
            $prec //= 0;
        } elsif ($conv eq 'm') {
            $data = $args{message};
        } elsif ($conv eq '%') {
            $data = '%';
        } else {
            # return as-is
            $fmt = '%s';
            $data = $all;
        }

        # sprintf format
        $fmt //= join("", grep {defined} (
            "%", $width, $dot, $prec, $sconv//"s"));

        sprintf $fmt, $data;

    };
    $template =~ s{$re}{$sub->(%args, indicator=>$self)}egox;

    $template;
}

1;
# ABSTRACT: Record progress to any output

=head1 SYNOPSIS

In your module:

 package MyApp;
 use Progress::Any;

 sub download {
     my @urls = @_;
     return unless @urls;
     my $progress = Progress::Any->get_indicator(
         task => "download", pos=>0, target=>~~@urls);
     for my $url (@urls) {
         # download the $url ...
         # update() by default increases pos by 1
         $progress->update(message => "Downloaded $url");
     }
     $progress->finish;
 }

In your application:

 use MyApp;
 use Progress::Any::Output;
 Progress::Any::Output->set('TermProgressBarColor');

 MyApp::download("url1", "url2", "url3", "url4", "url5");

When run, your application will display something like this, in succession:

  20% [====== Downloaded url1           ]0m00s Left
  40% [=======Downloaded url2           ]0m01s Left
  60% [=======Downloaded url3           ]0m01s Left
  80% [=======Downloaded url4==         ]0m00s Left

(At 100%, the output automatically cleans up the progress bar).

Another example, demonstrating multiple indicators and the LogAny output:

 use Progress::Any;
 use Progress::Any::Output;
 use Log::Any::App;

 Progress::Any::Output->set('LogAny', format => '[%t] [%P/%T] %m');
 my $p1 = Progress::Any->get_indicator(task => 'main.download');
 my $p2 = Progress::Any->get_indicator(task => 'main.copy');

 $p1->target(10);
 $p1->update(message => "downloading A");
 $p2->update(message => "copying A");
 $p1->update(message => "downloading B");
 $p2->update(message => "copying B");

will show something like:

 [main.download] [1/10] downloading A
 [main.copy] [1/?] copying A
 [main.download] [2/10] downloading B
 [main.copy] [2/?] copying B


=head1 STATUS

API might still change, will be stabilized in 1.0.


=head1 DESCRIPTION

C<Progress::Any> is an interface for applications that want to display progress
to users. It decouples progress updating and output, rather similar to how
L<Log::Any> decouples log producers and consumers (output). The API is also
rather similar to Log::Any, except I<Adapter> is called I<Output> and
I<category> is called I<task>.

Progress::Any records position/target and calculates elapsed time, estimated
remaining time, and percentage of completion. One or more output modules
(Progress::Any::Output::*) display this information.

In your modules, you typically only need to use Progress::Any, get one or more
indicators, set target and update it during work. In your application, you use
Progress::Any::Output and set/add one or more outputs to display the progress.
By setting output only in the application and not in modules, you separate the
formatting/display concern from the logic.

The list of features:

=over 4

=item * multiple progress indicators

You can use different indicator for each task/subtask.

=item * customizable output

Output is handled by one of C<Progress::Any::Output::*> modules. Currently
available outputs: C<Null> (no output), C<TermMessage> (display as simple
message on terminal), C<TermProgressBarColor> (display as color progress bar on
terminal), C<LogAny> (log using L<Log::Any>), C<Callback> (call a subroutine).
Other possible output ideas: IM/Twitter/SMS, GUI, web/AJAX, remote/RPC (over
L<Riap> for example, so that L<Perinci::CmdLine>-based command-line clients can
display progress update from remote functions).

=item * multiple outputs

One or more outputs can be used to display one or more indicators.

=item * hierarchical progress

A task can be divided into subtasks. If a subtask is updated, its parent task
(and its parent, and so on) are also updated proportionally.

=item * message

Aside from setting a number/percentage, allow including a message when updating
indicator.

=item * undefined target

Target can be undefined, so a bar output might not show any bar (or show them,
but without percentage indicator), but can still show messages.

=item * retargetting

Target can be changed in the middle of things.

=back


=head1 VARIABLES

=head2 $mtime => NUM

Unix timestamp of when update() is last called. Only a single value is needed
for this, that's why it is put as a package variable instead of object
attribute. When displaying remaining or elapsed time, the times are adjusted
against this value. For example, if C<update()> is called 3 seconds ago,
remaining time is assumed to decrease by 3 seconds and elapsed time to increase
by 3 seconds.


=head1 EXPORTS

=head2 $progress => OBJ

The root indicator. Equivalent to:

 Progress::Any->get_indicator(task => '')


=head1 ATTRIBUTES

Below are the attributes of an indicator/task:

=head2 task => STR* (default: from caller's package, or C<main>)

Task name. If not specified will be set to caller's package (C<::> will be
replaced with C<.>), e.g. if you are calling this method from
C<Foo::Bar::baz()>, then task will be set to C<Foo.Bar>. If caller is code
inside eval, C<main> will be used instead.

=head2 title => STR* (default: task name)

Specify task title. Task title is a longer description for a task and can
contain spaces and other characters. It is displayed in some outputs, as well as
using C<%t> in C<fill_template()>. For example, for a task called C<copy>, its
title might be C<Copying files to remote server>.

=head2 target => POSNUM (default: 0)

The total number of items to finish. Can be set to undef to mean that we don't
know (yet) how many items there are to finish (in which case, C<remaining> and
C<pctcomp> will also be set to undef to reflect this fact).

=head2 pos => POSNUM* (default: 0)

The number of items that are already done. It cannot be larger than C<target>,
if C<target> is defined. If C<target> is set to a value smaller than C<pos> or
C<pos> is set to a value larger than C<target>, C<pos> will be changed to be
C<target>.

=head2 state => STR (default: C<stopped>)

State of task/indicator. Either: C<stopped>, C<started>, or C<finished>.
Initially it will be set to C<stopped>, which means elapsed time won't be
running and will stay at 0. C<update()> will set the state to C<started> to get
elapsed time to run. At the end of task, you can call C<finish()> (or
alternatively set C<state> to C<finished>) to stop the elapsed time again.

The difference between C<stopped> and C<finished> is: when target and pos are
both at 0, C<pctcomp> will be set to 0 on C<stopped>, and 100 on C<finished>.

=head2 remaining => POSNUM (default: 0)

Estimated remaining time until the task is finished, in seconds. You can set
this value, for example at the beginning to give users an approximation, even
though you don't set C<target>. However, whenever C<pos> or C<target> is
set/changed, this attribute will be recalculated.

=head2 elapsed => FLOAT

A read-only attribute, elapsed time for this progress indicator. Elapsed time
starts at zero and does not run until state is set to C<started> (via
C<update()>).

=head2 pctcomp => NUM (default: 0)

Percentage of completion, a number between 0 and 100. This is a read-only
attribute and (re)calculated whenever there's a change in C<target> or C<pos> or
C<finished>: if C<target> is undef, C<pctcomp> will be undef, if C<target> is 0,
C<pctcomp> is set to 0 if C<finished> is false, or 100 if C<finished> is true.

=head2 ctime => NUM

A read-only attribute, Unix timestamp when the indicator is created. Currently
unused.


=head1 METHODS

=head2 Progress::Any->get_indicator(%args) => OBJ

Get a progress indicator for a certain task. C<%args> contain attribute values,
at least C<task> must be specified.

Note that this module maintains a list of indicator singleton objects for each
task (in C<%indicators> package variable), so subsequent C<get_indicator()> for
the same task will return the same object.


=head2 $progress->update(%args)

Update indicator. Will also, usually, update associated output(s) if necessary.

Arguments:

=over 4

=item * pos => NUM

Set the new position. If unspecified, defaults to current position + 1. If pos
is larger than target, outputs will generally still show 100%. Note that
fractions are allowed.

=item * message => STR

Set a message to be displayed when updating indicator.

=item * level => NUM

EXPERIMENTAL, NOT YET IMPLEMENTED BY MOST OUTPUTS. Setting the importance level
of this update. Default is C<normal> (or C<low> for fractional update), but can
be set to C<high> or C<low>. Output can choose to ignore updates lower than a
certain level.

=item * state => STR

Can be set to C<finished> to finish a task.

=back

=head2 $progress->finish(%args)

Equivalent to:

 $progress->update(
     ( pos => $progress->target ) x !!defined($progress->target),
     state => 'finished',
     %args,
 );

=head2 $progress->start()

Set state to C<started>.

=head2 $progress->stop()

Set state to C<stopped>.

=head2 $progress->fill_template($template)

Fill template with values, like in C<sprintf()>. Usually used by output modules.
Available templates:

=over

=item * C<%(width)n>

Task name (the value of the C<task> attribute). C<width> is optional, an
integer, like in C<sprintf()>, can be negative to mean left-justify instead of
right.

=item * C<%(width)t>

Task title (the value of the C<title> attribute).

=item * C<%(width)e>

Elapsed time. Currently using L<Time::Duration> concise format, e.g. 10s, 1m40s,
16m40s, 1d4h, and so on. Format might be configurable and localizable in the
future. Default width is -8. Examples:

 2m30s
 10s

=item * C<%(width)r>

Estimated remaining time (the value of the C<remaining> attribute). Currently
using L<Time::Duration> concise format, e.g. 10s, 1m40s, 16m40s, 1d4h, and so
on. Will show C<?> if unknown. Format might be configurable and localizable in
the future. Default width is -8. Examples:

 1m40s
 5s

=item * C<%(width)R>

Estimated remaining time I<or> elapsed time, if estimated remaining time is not
calculatable (e.g. when target is undefined). Format might be configurable and
localizable in the future. Default width is -8. Examples:

 30s left
 1m40s elapsed

=item * C<%(width).(prec)p>

Percentage of completion (the value of the C<pctcomp> attribute). C<width> and
C<precision> are optional, like C<%f> in Perl's C<sprintf()>, default is
C<%3.0p>. If percentage is unknown (due to target being undef), will show C<?>.

=item * C<%(width)P>

Current position (the value of the C<pos> attribute).

=item * C<%(width)T>

Target (the value of the C<target> attribute). If undefined, will show C<?>.

=item * C<%m>

Message (the C<update()> parameter). If message is unspecified, will show empty
string.

=item * C<%%>

A literal C<%> sign.

=back


=head1 FAQ

=head2 Why don't you use Moo?

Perhaps. For now I'm trying to be minimal and as dependency-free as possible.


=head1 SEE ALSO

Other progress modules on CPAN: L<Term::ProgressBar>,
L<Term::ProgressBar::Simple>, L<Time::Progress>, among others.

Output modules: C<Progress::Any::Output::*>

See examples on how Progress::Any is used by other modules: L<Perinci::CmdLine>
(supplying progress object to functions), L<Git::Bunch> (using progress object).

=cut
