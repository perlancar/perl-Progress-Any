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
            my $progress = $self->get_indicator(task => 'main');
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

# attributes of an indicator/task:
# - title (str*) = task's title
# - target (float)
# - pos (float*)
# - finished (bool)
# - ctime (float*) = creation time
# - st_target (float) = sum of all subtasks' target
# - remaining (float) = estimated remaining time
# - pctcomp (float) = calculated, percentage of completion
# - st_pos (float*) = sum of all subtasks' pos
# - st_min_ctime (float) = smallest ctime from subtasks
# - st_remaining (float) = sum of all subtasks' remaining time
# - lutime (float) = last update time, when displaying information
#                    remaining or elapsed need to be adjusted with (now-lutime)

# return 1 if created, 0 if already created/initialized
sub _init_indicator {
    my ($class, $task) = @_;
    return 0 if $indicators{$task};

    $indicators{$task} = bless({
        task      => $task,
        title     => $task,
        target    => 0,
        pos       => 0,
        remaining => undef,
        ctime     => time(),
        finished  => 0,
    }, $class);

    # if we create an indicator named a.b.c, we must also create a.b, a, and ''.
    if ($task =~ s/\.?\w+\z//) {
        $class->_init_indicator($task);
    }

    1;
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
    }
    die "Invalid task syntax '$task'" unless $task =~ /\A(?:\w+(\.\w+)*)?\z/;

    my $target    = delete($args{target});
    my $pos       = delete($args{pos}) // 0;
    my $title     = delete($args{title}) // $task;
    my $remaining = delete($args{remaining});
    die "Unknown argument(s) to get_indicator(): ".join(", ", keys(%args))
        if keys(%args);
    $class->_init_indicator($task);
    my $p = $indicators{$task};
    $p->title($title)     if exists($oargs{title});
    $p->remaining($title) if exists($oargs{remaining});
    $p->target($target)   if exists($oargs{target});
    $p->pos($pos)         if exists($oargs{pos});

    $p;
}

sub title {
    my $self = shift;
    if (@_) {
        my $oldtitle = $self->{title};
        my $title    = shift;
        $self->{title} = $title;
        return $self;
    } else {
        return $self->{title};
    }
}

sub remaining {
    my $self = shift;
    if (@_) {
        my $val = shift;
        die "Invalid value for remaining, must be a positive number"
            unless !defined($val) || $val >= 0;
        $self->{remaining} = $val;
        return $self;
    } else {
        return $self->{remaining};
    }
}

sub target {
    my $self = shift;
    if (@_) {
        my $val = shift;
        die "Invalid value for target, must be a positive number"
            unless !defined($val) || $val >= 0;
        $self->_update(target=>$val);
        return $self;
    } else {
        return $self->{target};
    }
}

sub pos {
    my $self = shift;
    if (@_) {
        my $val = shift;
        die "Invalid value for pos, must be a positive number"
            unless defined($val) && $val >= 0;
        $self->_update(pos=>$val);
        return $self;
    } else {
        return $self->{pos};
    }
}

# update an indicator's target/pos, and update pctcomp/remaining as well as
# parents' st_* attributes.
sub _update {
    my ($self, %args) = @_;

    return unless exists($args{target}) || exists($args{pos});

    if (exists $args{target}) {
        my $oldtarget = $self->{target};
        my $target    = $args{target};
        $self->{target} = $target;

        # update parents
        my $partask = $self->{task};
        while (1) {
            $partask =~ s/\.?\w+\z// or last;
            if (defined $target) {
                if (defined $oldtarget) {
                    $indicators{$partask}{ctarget} += $target-$oldtarget;
                } else {
                    # target becomes defined from undef, we need to recalculate
                    $indicators{$partask}{ctarget} = 0;
                  RECOUNT:
                    for (keys %indicators) {
                        my $prefix = length($partask) ? "$partask." : "";
                        next unless /\Q$prefix\E\w+/;
                        if (!defined($indicators{$_}{target})) {
                            $indicators{$partask}{ctarget} = undef;
                            last RECOUNT;
                        } else {
                            $indicators{$partask}{ctarget} +=
                                $indicators{$_}{target};
                        }
                    }
                }
            } else {
                # target is changed to undef
                $indicators{$partask}{target_} = undef;
            }
        }

    }

    if (exists $args{pos}) {
        my $oldpos = $self->{pos};
        my $pos    = $args{pos};
        $pos = $self->{target} if
            defined($self->{target}) && $pos > $self->{target};

        # update parents
    }
}

sub update {
    my ($self, %args) = @_;

    my $pos = delete($args{pos}) // $self->{pos} + 1;
    $self->_pos($pos);

    my $message  = delete($args{message});
    my $level    = delete($args{level});
    my $finished = delete($args{finished});
    die "Unknown argument(s) to update(): ".join(", ", keys(%args))
        if keys(%args);

    my $now = time();

    $self->{finished} = $finished;
    $self->{lutime}   = $now;

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

sub finish {
    my ($self, %args) = @_;
    $self->update(pos=>$self->{target}, finished=>1, %args);
}

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
     my $progress = Progress::Any->get_indicator(task => "download");
     $progress->pos(0);
     $progress->target(~~@urls);
     for my $url (@urls) {
         # download the $url ...
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

 Progress::Any::Output->set('LogAny', format => '[%c/%C] %m');
 my $p1 = Progress::Any->get_indicator(task => 'main.download');
 my $p2 = Progress::Any->get_indicator(task => 'main.copy');

 $p1->target(10);
 $p1->update(message => "downloading A"); # by default increase pos by 1
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


=head1 EXPORTS

=head2 $progress

The main indicator. Equivalent to:

 Progress::Any->get_indicator(task => 'main')


=head1 METHODS

=head2 Progress::Any->get_indicator(%args) => OBJ

Get a progress indicator for a certain task.

Arguments:

=over 4

=item * task => STR (default: main)

Required. Specify task name. If not specified will be set to caller's package
(C<::> will be replaced with C<.>), e.g. if you are calling this method from
C<main::foo()>, then task will be set to C<main>. If caller is code inside eval,
C<main> will be used instead.

=item * title => STR (default is task name)

Optional. Specify task title. Task title is a longer description for a task and
can contain spaces and other characters. For example, for a task called C<copy>,
its title might be C<Copying files to remote server>.

=item * remaining => NUM (default: undef)

Optional. Can be used to give estimation for remaining time, in seconds.

=item * target => NUM (default: undef)

Optional. Can be used to initialize target.

=item * pos => NUM (default: 0)

Optional. Can be used to initialize starting position.

=back

=head2 $progress->target([ NUM ]) => NUM

Get or (re)set target. Can be left or set to undef.

=head2 $progress->pos([ NUM ]) => NUM

Get or set the current position. Number must be defined and greater than or
equal to zero.

=head2 $progress->title([ STR ]) => STR

Get or set the task title.

=head2 $progress->remaining([ NUM ]) => NUM

Get or set estimated remaining time, in seconds. Number must be defined and
greater than or equal to zero. Note that estimated remaining time will be
recalculated everytime C<pos> or C<target> is updated.

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

=item * finished => BOOL

Can be set to 1 (e.g. by finish()) if task is completed.

=back

=head2 $progress->finish(%args)

Equivalent to:

 $progress->update(pos => $progress->target, finished=>1, %args);

The C<< finished => 1 >> part currently does nothing particularly special,
except to record completion.

=head2 $progress->fill_template($template, \%values)

Fill template with values, like in C<sprintf()>. Usually used by output modules.
Available templates:

=over

=item * C<%(width)t>

Task name. C<width> is optional, an integer, like in C<sprintf()>, can be
negative to mean left-justify instead of right.

=item * C<%(width)e>

Elapsed time. Currently using L<Time::Duration> concise format, e.g. 10s, 1m40s,
16m40s, 1d4h, and so on. Format might be configurable and localizable in the
future. Default width is -8. Examples:

 2m30s
 10s

=item * C<%(width)r>

Estimated remaining time. Currently using L<Time::Duration> concise format, e.g.
10s, 1m40s, 16m40s, 1d4h, and so on. Will show C<?> if unknown. Format might be
configurable and localizable in the future. Default width is -8. Examples:

 1m40s
 5s

=item * C<%(width)d>

Estimated total duration of task (which equals to elapsed + remaining time).
Will show C<?> if remaining time is unknown. Currently using L<Time::Duration>
concise format, e.g. 10s, 1m40s, 16m40s, 1d4h, and so on. Format might be
configurable and localizable in the future. Examples:

 4m10s
 15s

=item * C<%(width)R>

Estimated remaining time I<or> elapsed time, if estimated remaining time is not
calculatable (e.g. when target is undefined). Format might be configurable and
localizable in the future. Default width is -8. Examples:

 1m40s elapsed
 30s left

=item * C<%(width).(prec)p>

Percentage of completion. C<width> and C<precision> are optional, like C<%f> in
Perl's C<sprintf()>, default is C<%3.0p>. If percentage is unknown (due to
target being undef), will show C<?>.

=item * C<%(width)P>

Current position (pos).

=item * C<%(width)T>

Target. If undefined, will show C<?>.

=item * C<%m>

Message. If message is unspecified, will show empty string.

=item * C<%%>

A literal C<%> sign.

=back


=head1 SEE ALSO

Other progress modules on CPAN: L<Term::ProgressBar>,
L<Term::ProgressBar::Simple>, L<Time::Progress>, among others.

Output modules: C<Progress::Any::Output::*>

See examples on how Progress::Any is used by other modules: L<Perinci::CmdLine>
(supplying progress object to functions), L<Git::Bunch> (using progress object).

=cut
