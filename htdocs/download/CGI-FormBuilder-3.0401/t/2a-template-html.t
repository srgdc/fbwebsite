#!/usr/bin/perl -Ilib -I../lib

# Copyright (c) 2000-2006 Nathan Wiger <nate@wiger.org>.
# All Rights Reserved. If you're reading this, you're bored.
# 2a-template-html.t - test HTML::Template support

use strict;
use vars qw($TESTING $DEBUG $SKIP);
$TESTING = 1;
$DEBUG = $ENV{DEBUG} || 0;

use Test;

# use a BEGIN block so we print our plan before CGI::FormBuilder is loaded
BEGIN {
    my $numtests = 4;

    plan tests => $numtests;

    # try to load template engine so absent template does
    # not cause all tests to fail
    eval "require HTML::Template";
    $SKIP = $@ ? 'skip: HTML::Template not installed here' : 0;   # eval failed, skip all tests

    # success if we said NOTEST
    if ($ENV{NOTEST}) {
        ok(1) for 1..$numtests;
        exit;
    }
}

# Need to fake a request or else we stall
$ENV{REQUEST_METHOD} = 'GET';
$ENV{QUERY_STRING}   = 'ticket=111&user=pete&replacement=TRUE';

use CGI::FormBuilder 3.0401;
use CGI::FormBuilder::Test;

# Grab our template from our test00.html file
my $template = outfile(0);

# What options we want to use, and what we expect to see
my @test = (
    {
        opt => { fields => [qw/name color/], 
                 submit => 0, 
                 reset  => 'No esta una button del submito',
                 template => { scalarref => \$template },
                 validate => { name => 'NAME' },
                 
               },
        mod => { color => { options => [qw/red green blue/], nameopts => 1 },
                 size  => { value => 42 } },

    },
    {
        opt => { fields => [qw/name color size/],
                 template => { scalarref => \$template },
                 values => {color => [qw/purple/], size => 8},
                 reset => 'Start over, boob!',
                 validate => {},    # should be empty
               },

        mod => { color => { options => [qw/white black other/] },
                 name => { size => 80 } },

    },
    {
        opt => { fields => [qw/name color email/], submit => [qw/Update Delete/], reset => 0,
                 template => { scalarref => \$template },
                 values => {color => [qw/yellow green orange/]},
                 validate => { color => [qw(red blue yellow pink)] },
               },

        mod => { color => {options => [[red => 1], [blue => 2], [yellow => 3], [pink => 4]] },
                 size  => {value => '(unknown)' } 
               },

    },
);

# Perl 5 is sick sometimes.
@test = @test[$ARGV[0] - 1] if @ARGV;
my $seq = $ARGV[0] || 1;

# Cycle thru and try it out
for (@test) {
    my $form = CGI::FormBuilder->new(
                    debug => $DEBUG,
                    action => 'TEST',
                    title  => 'TEST',
                    %{ $_->{opt} },
               );

    # the ${mod} key twiddles fields
    while(my($f,$o) = each %{$_->{mod} || {}}) {
        $o->{name} = $f;
        $form->field(%$o);
    }

    #
    # Just compare the output of render with what's expected
    # the correct string output is now in external files.
    # The seemingly extra eval is required so that failures
    # to import the template modules do not kill the tests.
    # (since render is called regardless of whether $SKIP is set)
    #
    my $out = outfile($seq++);
    my $ren = $SKIP ? '' : $form->render;
    my $ok = skip($SKIP, $ren, $out);

    if (! $ok && $ENV{LOGNAME} eq 'nwiger') {
        open(O, ">/tmp/fb.1.out");
        print O $out;
        close O;

        open(O, ">/tmp/fb.2.out");
        print O $ren;
        close O;

        system "diff /tmp/fb.1.out /tmp/fb.2.out";
        exit 1;
    }
}

# MORE TESTS DOWN HERE

# from eszpee for tmpl_param
skip($SKIP, do{
    my $form2 = CGI::FormBuilder->new(
                    template => { scalarref => \'<TMPL_VAR test>' }
                );
    $form2->tmpl_param(test => "this message should appear");
    eval '$form2->render';
}, 'this message should appear');

