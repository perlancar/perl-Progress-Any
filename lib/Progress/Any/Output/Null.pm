package Progress::Any::Output::Null;

use 5.010;
use strict;
use warnings;

# VERSION

sub new {
    my ($class, %args) = @_;
    bless \%args, $class;
}

sub update {
    1;
}

1;
# ABSTRACT: Null output
