package Progress::Any;

use 5.010;
use strict;
use warnings;

use Progress::Any::Output::Null;

#use overload
#    '++' => \&_increment,
#    '+=' => \&_increment,
#    '--' => \&_decrement,
#    '-=' => \&_decrement,
#    ;

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

A simple example:

 use Progress::Any qw($progress);
 use Progress::Any::Output::Terminal;

 $progress->init(
     target  => 10,
     output  => Progress::Any::Output::Terminal->new(...),
 );
 for (1..10) {
     $progress->update(
         pos     => $_,
         message => "Doing item #$_ ...",
     );

     # ditto, without message, demonstrating overloading
     $progress++;

     sleep 1;
 }
 $progress->finish; # no-op here, since update() has been called 10 times

Another example, demonstrating multiple indicators:

 use Progress::Any;

 Progress::Any->set_output(output=>Progress::Any::Output::LogAny->new);
 my $p1 = Progress::Any->get_indicator(task => 'main.download');
 my $p2 = Progress::Any->get_indicator(task => 'main.copy');

 $p1->set_target(target => 10);
 $p1->update();
 $p2->update();


=head1 STATUS

API is not stable yet.


=head1 DESCRIPTION

C<Progress::Any> is an interface for applications that want to display progress
to users. It decouples progress updating and output, rather similar to how
L<Log::Any> decouple log producers and consumers (output). By setting output
only in the application and not in modules, you separate the formatting/display
concern from the logic.

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

Target can be undefined, so a bar output might not show any bar, but can still
show messages.

=back


=head1 EXPORTS

=head2 $progress

The main indicator. Equivalent to:

 Progress::Any->get_indicator(task => 'main')


=head1 METHODS

None of the functions are exported by default, but they are exportable.

=head2 Progress::Any->get_indicator(%args)

Get a progress indicator.

Arguments:

=over 4

=item * task => STR (default: main)

=back

=head2 Progress::Any->set_output(%args)

Set default output for newly created indicators. Arguments:

=over 4

=item * task => STR

Select task to set the output for. If unset, will set for newly created
indicators.

=item * output => OBJ

If unset, will use parent task's output, or if no parent exists, default output
(which is the null output).

=back

=head2 $progress->init(%args)

Initialize the indicator. Should only be called once.

Arguments:

=over 4

=item * target => NUM

=item * output => OBJ or ARRAY

Set the output(s) for this indicator. If unset, will use the default indicator
set by C<set_output>.

=back

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

=head2 $progress->set_target(target => $target)

(Re-)set target. Will also update output if necessary.

=head2 $progress->reset

Reset indicator back to zero. Will also update output if necessary.

=head2 $progress->finish

Set indicator to 100%. Will also update output if necessary.


=head1 SEE ALSO

Other progress modules on CPAN: L<Term::ProgressBar>,
L<Term::ProgressBar::Simple>, L<Time::Progress>, among others.

Output modules: C<Progress::Any::Output::*>

=cut

