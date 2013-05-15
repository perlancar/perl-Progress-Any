package Progress::Any;

use 5.010;
use strict;
use warnings;

use Progress::Any::Output::Null;

# VERSION

sub import {
    my ($self, @args) = @_;
    my $caller = caller();
    for (@args) {
        if ($_ eq '$progress') {
            my $progress = $self->get_indicator(task => 'main', _init=>0);
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

my %indicators; # key = task
my $default_output = Progress::Any::Output::Null->new;

sub get_indicator {
    my ($class, %args) = @_;

    my $task   = delete($args{task}) // "main";
    my $target = delete($args{target});
    my $output = delete($args{output});
    my $init   = delete($args{_init}) // 1;
    die "Unknown argument(s): ".join(", ", keys(%args)) if keys(%args);
    if (!$indicators{$task}) {
        $indicators{$task} = bless({task=>$task}, $class);
        $indicators{$task}->init(target=>$target, output=>$output)
            if $init;
    }
    $indicators{$task};
}

sub set_output {
    my ($class, %args) = @_;
    my $output = $args{output} or die "Please specify output";

    if (my $task = $args{task}) {
        if ($indicators{$task}) {
            $indicators{$task}{output} = $output;
        } else {
            die "Unknown indicator '$task'";
        }
    } else {
        $default_output = $output;
    }
}

sub init {
    my ($self, %args) = @_;
    die "Already initialized" if $self->{_init}++;

    $self->{task}   = $args{task} if !defined($self->{task});
    $self->{target} = $args{target};
    $self->{output} = $args{output};
    $self->{pos}    = 0;
}

sub set_target {
    my ($self, %args) = @_;
    $self->{target} = $args{target};
    $self->update(pos => $self->{pos});
}

sub update {
    my ($self, %args) = @_;
    if (defined(my $pos = delete($args{pos}))) {
        $self->{pos} = $pos;
    } else {
        my $inc = delete($args{inc}) // 1;
        $self->{pos} += $inc;
    }
    $self->{pos} = 0 if $self->{pos} < 0;
    $self->{pos} = $self->{target} if
        defined($self->{target}) && $self->{pos} > $self->{target};

    my $message = delete($args{message});
    my $level   = delete($args{level});
    my $status  = delete($args{status});
    die "Unknown argument(s): ".join(", ", keys(%args)) if keys(%args);

    # find output and call it
    my $output;
    my $task = $self->{task};
    my $ind = $self;
    while (1) {
        $output = $ind->{output} if $ind;
        last if defined $output;
        $task =~ s/\.[^.]+\z// or last;
        $ind = $indicators{$task};
    }
    $output //= $default_output;

    my %uargs = (target=>$self->{target}, pos=>$self->{pos},
                 message=>$message, level=>$level, status=>$status);
    for (ref($output) eq 'ARRAY' ? @$output : ($output)) {
        $output->update(%uargs);
    }
}

sub reset {
    my ($self, %args) = @_;
    $args{message} //= "Reset";
    $args{pos} = 0;
    $self->update(%args);
}

sub finish {
    my ($self, %args) = @_;
    if (defined $self->{target}) {
        $args{message} //= "Finish";
        $args{pos} = $self->{target};
        $self->update(%args);
    }
}

#sub _increment {
#    my ($self, $inc) = @_;
#    $inc //= 1;
#    $self->update(inc=>$inc);
#}
#
#sub _decrement {
#    my ($self, $dec) = @_;
#    $dec //= 1;
#    $self->update(inc=>-$dec);
#}

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

 Progress::Any::Output->set('LogAny');
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

=item * hierarchiecal progress

A task can be divided into subtasks. After a subtask finishes, its parent task's
progress is incremented by 1 automatically (and if I<that> task is finished,
I<its> parent is updated, and so on).

=item * customizable output

Output is handled by one of C<Progress::Any::Output::*> modules. Each indicator
can use one or more outputs. Currently available outputs: null, terminal, log
(to L<Log::Any>), callback. Other possible output ideas: IM/twitter/SMS, GUI,
web/AJAX, remote/RPC (over L<Riap> for example, so that
L<Perinci::CmdLine>-based command-line clients can display progress update from
remote functions).

=item * message

Aside from setting a number/percentage, allow including a message when updating
indicator.

=item * indicator reset

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

Get a progress indicator.

Arguments:

=over 4

=item * task => STR (default: main)

If not specified will be set to caller's package + subroutine, e.g. if you are
calling this method from C<main::foo>, then task will be set to C<main.foo>.

=back

=head2 $progress->target([ NUM ]) => NUM

Get or (re)set target. Can be left or set to undef.

=head2 $progress->pos([ NUM ]) => NUM

Get or set current position.

=head2 $progress->update(%args)

Update indicator. Will optionally update each associated output(s) if necessary.
By necessary it means if update maximum frequency and other output's settings
are not violated.

Arguments:

=over 4

=item * pos => NUM

Set the new position. If unspecified, defaults to current position + 1. If pos
is larger than target, outputs will generally still show 100%. Note that
fractions are allowed.

=item * inc => NUM

If C<pos> is not specified, this parameter is used instead, to increment the
current position by a certain number (the default is 1). Note that fractions are
allowed.

=item * message => STR

Set a message to be displayed when updating indicator.

=item * level => STR

EXPERIMENTAL. Setting the importance level of this update. Default is C<normal>
(or C<low> for fractional update), but can be set to C<high> or C<low>. Output
can choose to ignore updates lower than a certain level.

=item * status => STR

Set the status of this update. Some outputs interpret/display this, for example
the Console:

Update:

 $progress->update(pos=>2, message=>'Copying file ...');

Output (C<_> indicates cursor position):

 Copying file ... _

Update:

 $progress->update(pos=>2, status=>'success');

Output:

 Copying file ... success
 _

=back

=head2 $progress->finish(%args)

Set indicator to 100% and update output. Equivalent to:

 $progress->update(pos => $progress->target, %args);

except that it will still display 100% even though target is unknown/undef.


=head1 SEE ALSO

Other progress modules on CPAN: L<Term::ProgressBar>,
L<Term::ProgressBar::Simple>, L<Time::Progress>, among others.

Output modules: C<Progress::Any::Output::*>

See examples on how Progress::Any is used by other modules: L<Perinci::CmdLine>
(supplying progress object to functions), L<Git::Bunch> (using progress object).

=cut

