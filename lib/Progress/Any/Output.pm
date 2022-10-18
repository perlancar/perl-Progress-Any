package Progress::Any::Output;

use 5.010001;
use strict;
use warnings;

require Progress::Any;

# AUTHORITY
# DATE
# DIST
# VERSION

sub import {
    my $self = shift;
    __PACKAGE__->set(@_) if @_;
}

sub _set_or_add {
    my $class = shift;
    my $which = shift;

    my $opts;
    if (@_ && ref($_[0]) eq 'HASH') {
        $opts = {%{shift()}}; # shallow copy
    } else {
        $opts = {};
    }

    # allow adding options via -name => val syntax, for ease in using via -M in
    # one-liners.
    while (1) {
        last unless @_ && $_[0] =~ /\A-(.+)/;
        $opts->{$1} = $_[1];
        splice @_, 0, 2;
    }

    my $output = shift or die "Please specify output name";
    $output =~ /\A(?:\w+(::\w+)*)?\z/ or die "Invalid output syntax '$output'";

    my $task = $opts->{task} // "";

    my $outputo;
    unless (ref $outputo) {
        (my $outputpm = "$output.pm") =~ s!::!/!g;
        require "Progress/Any/Output/$outputpm"; ## no critic: Modules::RequireBarewordIncludes
        $outputo = "Progress::Any::Output::$output"->new(@_);
    }

    if ($which eq 'set') {
        $Progress::Any::outputs{$task} = [$outputo];
    } else {
        $Progress::Any::outputs{$task} //= [];
        push @{ $Progress::Any::outputs{$task} }, $outputo;
    }

    $outputo;
}

sub set {
    my $class = shift;
    $class->_set_or_add('set', @_);
}

sub add {
    my $class = shift;
    $class->_set_or_add('add', @_);
}

1;
# ABSTRACT: Assign output to progress indicators

=head1 SYNOPSIS

In your application:

 use Progress::Any::Output;
 Progress::Any::Output->set('TermProgressBarColor');

or:

 use Progress::Any::Output 'TermProgressBarColor';

To give parameters to output:

 use Progress::Any::Output;
 Progress::Any::Output->set('TermProgressBarColor', width=>50, ...);

or:

 use Progress::Any::Output 'TermProgressBarColor', width=>50, ...;

To assign output to a certain (sub)task:

 use Progress::Any::Output -task => "main.download", 'TermMessage';

or:

 use Progress::Any::Output;
 Progress::Any::Output->set({task=>'main.download'}, 'TermMessage');

To add additional output, use C<add()> instead of C<set()>.


=head1 DESCRIPTION

See L<Progress::Any> for overview.


=head1 METHODS

=head2 Progress::Any::Output->set([ \%opts ], $output[, @args]) => obj

Set (or replace) output. Will load and instantiate
C<Progress::Any::Output::$output>. To only set output for a certain (sub)task,
set C<%opts> to C<< { task => $task } >>. C<@args> will be passed to output
module's constructor.

Return the instantiated object.

If C<$output> is an object (a reference, really), it will be used as-is.

=head2 Progress::Any::Output->add([ \%opts ], $output[, @args])

Like set(), but will add output instead of replace existing one(s).


=head1 SEE ALSO

L<Progress::Any>

=cut
