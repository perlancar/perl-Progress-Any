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

our %indicators; # key = task
our %outputs;    # key = task, value = [$outputobj, ...]

# attributes of indicator:
# - target (float)
# - pos (float*)
# - finished (bool)
# - ctime (float*) = creation time
# - ctarget (float) = (computed) total of subtasks' targets (incl indirect)
# - elapseds (array of float*) = elapsed time since last updates (for calculating eta)
# - incs (array of float*) = pos increment of last updates (ditto)
# - lutime (float) = last update time

sub get_indicator {
    my ($class, %args) = @_;

    my $task   = delete($args{task});
    if (!defined($task)) {
        my @caller = caller(0);
        #say "D:caller=".join(",",map{$_//""} @caller);
        $task = $caller[0] eq '(eval)' ? 'main' : $caller[0];
        $task =~ s/::/./g;
    }
    die "Invalid task syntax '$task'" unless $task =~ /\A(?:\w+(\.\w+)*)?\z/;
    my $target   = delete($args{target});
    my $pos      = delete($args{pos}) // 0;
    my $finished = delete($args{finished});
    die "Unknown argument(s) to get_indicator(): ".join(", ", keys(%args))
        if keys(%args);
    if (!$indicators{$task}) {
        $indicators{$task} = bless({
            task     => $task,
            ctime    => time(),
            finished => $finished,
            target   => $target,
            pos      => $pos,
        }, $class);

        # automatically initialize/update parent tasks
        my $partask = $task;
        while (1) {
            last unless $partask =~ s/\.?\w+\z//;
            if (!$indicators{$partask}) {
                $indicators{$partask} = bless({
                    task     => $partask,
                    pos      => 0,
                    target   => 0,
                    ctime    => time(),
                }, $class);
            }
            if (defined $target) {
                if (defined $indicators{$partask}{target}) {
                    $indicators{$partask}{ctarget} += $target
                        if !exists($indicators{$partask}{ctarget}) ||
                            defined($indicators{$partask}{ctarget});
                }
            } else {
                $indicators{$partask}{ctarget} = undef;
            }
            $indicators{$partask}{pos} += $pos;
        }
    }
    $indicators{$task};
}

sub target {
    my $self = shift;
    if (@_) {
        my $oldtarget = $self->{target};
        my $target    = shift;
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
                        next unless /\Q$prefix\E\w+\z/;
                        if (!defined($indicators{$_}{target})) {
                            $indicators{$partask}{ctarget} = undef;
                            last RECOUNT;
                        } else {
                            $indicators{$partask}{ctarget} +=
                                $indicators{$_}{target} +
                                    ($indicators{$_}{ctarget} // 0);
                        }
                    }
                }
            } else {
                $indicators{$partask}{ctarget} = undef;
            }
        }

        return $self;
    } else {
        return $self->{target};
    }
}

sub total_target {
    my $self = shift;
    return undef unless defined($self->{target});
    return undef if exists($self->{ctarget}) && !defined($self->{ctarget});
    $self->{target} + ($self->{ctarget} // 0);
}

sub pos {
    my $self = shift;
    if (@_) {
        my $oldpos = $self->{pos};
        my $pos    = shift;
        $self->{pos} = $pos;

        # update parents
        my $partask = $self->{task};
        while (1) {
            $partask =~ s/\.?\w+\z// or last;
            $indicators{$partask}{pos} += $pos-$oldpos;
        }

        return $self;
    } else {
        return $self->{pos};
    }
}

my $TIMES_HIST = 5;
sub update {
    my ($self, %args) = @_;

    my $time = time();
    my $oldpos = $self->{pos};

    # check arguments
    if (defined(my $pos = delete($args{pos}))) {
        $self->{pos} = $pos;
    } else {
        $self->{pos} += 1;
    }
    $self->{pos} = 0 if $self->{pos} < 0;
    $self->{pos} = $self->{target} if
        defined($self->{target}) && $self->{pos} > $self->{target};
    my $message  = delete($args{message});
    my $level    = delete($args{level});
    my $status   = delete($args{status});
    my $finished = delete($args{finished});
    die "Unknown argument(s) to update(): ".join(", ", keys(%args))
        if keys(%args);

    $self->{finished} = $finished;

    # record times/increments
    my $inc = $self->{pos} - $oldpos;
    my $elapsed = $self->{lutime} ? $time-$self->{lutime}:$time-$self->{ctime};
    push @{ $self->{incs} }, $inc;
    push @{ $self->{elapseds} }, $elapsed;
    if (@{ $self->{incs} } > $TIMES_HIST) {
        shift @{$self->{elapseds}};
        shift @{$self->{incs}};
    }

    # update parents' pos & times
    my $partask = $self->{task};
    while (1) {
        $partask =~ s/\.?\w+\z// or last;
        my $par = $indicators{$partask};
        $par->{pos} += $inc;
        push @{ $par->{incs} }, $inc;
        push @{ $par->{elapseds} }, $elapsed;
        if (@{ $par->{incs} } > $TIMES_HIST) {
            shift @{$par->{elapseds}};
            shift @{$par->{incs}};
        }
    }

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
                        status    => $status,
                        time      => $time,
                    );
                }
            }
            last unless $task =~ s/\.?\w+\z//;
        }
    }

    $self->{lutime} = $time;
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
                           [taepcCm%])
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
        } elsif ($conv =~ /[epC]/o) {
            my $tot = $p->total_target;
            if (!defined($tot)) {
                $data = '?';
            } else {
                if ($conv eq 'e') {
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
                    } else {
                        $data = '?';
                    }
                } elsif ($conv eq 'p' || $conv eq 'C') {
                    $sconv = 'f';
                    $dot = '.';
                    $prec //= 0;
                    if ($conv eq 'p') {
                        $data = $p->{pos} / $tot * 100.0;
                        $width //= 3;
                    } else {
                        $data = $tot;
                    }
                } else {
                    $data = "TODO";
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
    $template =~ s{$re}{$sub->(%args)}egox;

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

 [1/10] downloading A
 [1/?] copying A
 [2/10] downloading B
 [2/?] copying B


=head1 STATUS

API might still change, will be stabilized in 1.0.


=head1 DESCRIPTION

C<Progress::Any> is an interface for applications that want to display progress
to users. It decouples progress updating and output, rather similar to how
L<Log::Any> decouples log producers and consumers (output). The API is also
rather similar to Log::Any, except I<Adapter> is called I<Output> and
I<category> is called I<task>.

Progress::Any records position/target and calculation of times (elapsed,
remaining). One of the output modules (Progress::Any::Output::*) displays this
information.

In your modules, you typically only needs to use Progress::Any, get one or more
indicators, set position/target and update it during work. In your application,
you use Progress::Any::Output and set/add one or more outputs to display the
progress. By setting output only in the application and not in modules, you
separate the formatting/display concern from the logic.

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

=item * hierarchiecal progress

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

If not specified will be set to caller's package (C<::> will be replaced with
C<.>), e.g. if you are calling this method from C<main::foo()>, then task will
be set to C<main>. If caller is code inside eval, C<main> will be used instead.

=item * target => NUM (default: undef)

Optional. Can be used to initialize target. Will only be done once for the same
task and not for the subsequent get_indicator() calls on the same task.

=item * pos => NUM (default: 0)

Optional. Can be used to initialize starting position. Will only be done once
for the same task and not for the subsequent get_indicator() calls on the same
task.

=back

=head2 $progress->target([ NUM ]) => NUM

Get or (re)set target. Can be left or set to undef.

=head2 $progress->pos([ NUM ]) => NUM

Get or set the current position.

=head2 $progress->total_target => NUM

Get total target, which is target plus all the descendant's targets. If any of
those is undefined, return undef.

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

=item * status => STR

Set the status of this update, usually done on finish(). Some outputs
interpret/display this, for example the C<TermMessage> output:

Update:

 my $progress = Progress::Any->get_indicator(
     task => 'copy', message => 'Copying file ...');
 $progress->update(message=>'file1.txt');

Output:

 Copying file ... file1.txt

Update:

 $progress->finish(status=>'success');

Output:

 Copying file ... success

=item * finished => BOOL

Can be set to 1 (e.g. by finish()) if task is completed.

=back

=head2 $progress->finish(%args)

Equivalent to:

 $progress->update(pos => $progress->target, finished=>1, %args);

The C<< finished => 1 >> part currently does nothing particularly special,
except to record completion.

=head2 $progress->fill_template($template, \%values)

Fill template with values, like in sprintf. Usually used by output modules.
Available templates:

=over

=item * C<%(width)t>

B<T>ask.

=item * C<%(width)a>

Elapsed time. Currently using L<Time::Duration> concise format, e.g. 10s, 1m40s,
16m40s, 1d4h, and so on. Format might be configurable and localizable in the
future.

=item * C<%e>

Estimated completion time. Currently using L<Time::Duration> concise format,
e.g. 10s, 1m40s, 16m40s, 1d4h, and so on. Format might be configurable and
localizable in the future.

=item * C<%(width).(prec)p>

Percentage of completion. You can also specify width and precision, like C<%f>
in Perl sprintf. Default is C<%3.0p>. If percentage is unknown (due to target
being undef) will translate to C<?>.

=item * C<%(width).(prec)c>

Current position (pos) (or B<c>ounter).

=item * C<%(width).(prec)C>

Target (or total item B<c>ount). If undefined, will translate to C<?>.

=item * C<%m>

B<M>essage. If message is unspecified, translate to empty string.

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

