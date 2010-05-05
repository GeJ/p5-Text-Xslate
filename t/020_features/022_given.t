#!perl -w

use strict;
use Test::More;

use Text::Xslate;

my $tx = Text::Xslate->new();

my $tmpl = <<'T';
: given $value {
:    when "foo" {
        FOO
:    }
:    when "bar" {
        BAR
:    }
:    default {
        BAZ
:    }
: }
T

my @set = (
    [$tmpl, { value => "foo" }, <<'X', 'given-when (1)'],
        FOO
X
    [$tmpl, { value => "bar" }, <<'X', 'given-when (2)'],
        BAR
X
    [$tmpl, { value => undef }, <<'X', 'given-when (default)'],
        BAZ
X
    [<<'T', { value => undef }, <<'X', 'default can be the first'],
: given $value {
:    default {
        BAZ
:    }
:    when "foo" {
        FOO
:    }
:    when "bar" {
        BAR
:    }
: }
T
        BAZ
X

);

foreach my $d(@set) {
    my($in, $vars, $out, $msg) = @$d;
    is $tx->render_string($in, $vars), $out, $msg or diag $in;
}


done_testing;
