
package CGI::FormBuilder;

# Copyright (c) 2000-2005 Nathan Wiger <nate@sun.com>. All Rights Reserved.
# Please visit www.formbuilder.org for tutorials, support, and examples.
# Use "perldoc FormBuilder.pm" for complete documentation.

=head1 NAME

CGI::FormBuilder - Easily generate and process stateful forms

=head1 SYNOPSIS

    use CGI::FormBuilder;

    # Assume we did a DBI query to get existing values
    my $dbval = $sth->fetchrow_hashref;

    # First create our form
    my $form = CGI::FormBuilder->new(
                    fields   => [qw(name email phone gender)],
                    header   => 1,
                    method   => 'POST',
                    values   => $dbval,
                    validate => {
                       email => 'EMAIL',
                       phone => '/^1?-?\d{3}-?\d{3}-?\d{4}$/',
                    },
                    required => 'ALL',
                    stylesheet => '/path/to/style.css',
               );

    # Change gender field to have options
    $form->field(name => 'gender', options => [qw(Male Female)] );

    if ($form->submitted && $form->validate) {
        # Get form fields as hashref
        my $fields = $form->fields;

        # Do something to update your data (you would write this)
        do_data_update($fields->{name}, $fields->{email},
                       $fields->{phone}, $fields->{gender});

        # Show confirmation screen
        print $form->confirm;
    } else {
        # Print out the form
        print $form->render;
    }

=cut

use Carp;
use strict;
use vars qw($VERSION $AUTOLOAD %DEFOPTS %REARRANGE);

use CGI::FormBuilder::Util;
use CGI::FormBuilder::Field;
use CGI::FormBuilder::Messages;

$VERSION = '3.01';

# Default options for FormBuilder
%DEFOPTS = (
    sticky     => 1,
    method     => 'GET',
    submit     => 'Submit',
    reset      => 'Reset',
    submitname => '_submit',
    resetname  => '_reset',
    body       => { bgcolor => 'white' },
    text       => '',
    table      => { border => 0 },
    tr         => { valign => 'middle' },
    td         => { align  => 'left' },
    jsname     => 'validate',
    sessionidname => '_sessionid',
    submittedname => '_submitted',
    template     => '',               # default template
    debug      => 0,                  # can be 1 or 2
    javascript => 'auto',             # 0, 1, or 'auto'
    render     => 'render',           # render sub name
    smartness  => 1,                  # can be 1 or 2
    selectnum  => 5,
    stylesheet => 0,                  # use stylesheet stuff?
    styleclass => 'fb_',              # prefix for style
    doctype    => <<EOD,              # stolen from CGI.pm
<?xml version="1.0" encoding="iso-8859-1"?>
<!DOCTYPE html
        PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"
         "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" lang="en-US" xml:lang="en-US">
EOD
);

# Which options to rearrange from new() into field()
%REARRANGE = qw(
    options     options
    labels      label
    validate    validate
    required    required
    selectnum   selectnum
    sortopts    sortopts
    nameopts    nameopts
    sticky      sticky
);

*redo = \&new;
sub new {
    local $^W = 0;      # -w sucks
    my $self = shift;
    my %opt = cleanargs(@_);

    # old options
    $opt{td}{align} = delete $opt{lalign} if $opt{lalign};

    if (ref $self) {
        # cloned/original object
        debug 1, "rewriting existing FormBuilder object";
        while (my($k,$v) = each %opt) {
            $self->{$k} = $v;
        }
    } else {
        debug 1, "constructing new FormBuilder object";
        # damn deep copy this is SO damn annoying
        while (my($k,$v) = each %DEFOPTS) {
            next if exists $opt{$k};
            if (ref $v eq 'HASH') {
                $opt{$k} = { %$v };
            } elsif (ref $v eq 'ARRAY') {
                $opt{$k} = [ @$v ];
            } else {
                $opt{$k} = $v;
            }
        }
        $self = bless \%opt, $self;
    }

    # Create our CGI object if not present
    unless ($self->{params} && ref $self->{params} ne 'HASH') {
        require CGI;
        $CGI::USE_PARAM_SEMICOLONS = 0;     # fuck ; in urls
        $self->{params} = CGI->new($self->{params});
    }

    # And a messages delegate if not existent
    unless ($self->{messages} && ref $self->{messages} ne 'HASH') {
        $self->{messages} = CGI::FormBuilder::Messages->new($self->{messages});
    }

    # XXX not mod_perl safe (problem)
    $CGI::FormBuilder::Util::DEBUG = $self->{debug};

    # Initialize form fields (probably a good idea)
    if ($self->{fields}) {
        debug 1, "creating fields list";

        # check to see if 'fields' is a hash or array ref
        my $ref = ref $self->{fields};
        if ($ref && $ref eq 'HASH') {
            # with a hash ref, we setup keys/values
            debug 2, "got list from HASH";
            while(my($k,$v) = each %{$self->{fields}}) {
                $k = lc $k;     # must lc to ignore case
                $self->{values}{$k} = [ autodata $v ];
            }
            # reset main fields to field names
            $self->{fields} = [ sort keys %{$self->{fields}} ];
        } else {
            # rewrite fields to ensure format
            debug 2, "got list from ARRAY";
            $self->{fields} = [ autodata $self->{fields} ];
        }
    }

    # Catch the intersection of required and validate
    if ($self->{required} && $self->{validate}) {
        # ok, will handle itself automatically below
    } elsif ($self->{required}) {
        # ok, validate will default to values
    } elsif ($self->{validate}) {
        # construct a required list of all validated fields
        $self->{required} = [ keys %{$self->{validate}} ];
    }

    # Now, new for the 3.x series, we cycle thru the fields list and
    # replace it with a list of objects, which stringify to field names
    my @ftmp  = ();
    for (@{$self->{fields}}) {
        my %fprop = ();     # holds field properties
        $fprop{name}  = $_;

        if (ref $_ eq 'CGI::FormBuilder::Field') {
            # is an existing Field object, so update its properties
            $_->field(%fprop);
        } else {
            # init a new one
            $_ = $self->newfield(%fprop);
        }
        debug 2, "push \@(@ftmp), $_";
        push @ftmp, $_;
    }

    # stringifiable objects (overwrite previous container)
    $self->{fields} = \@ftmp;

    # setup values
    $self->values($self->{values}) if $self->{values};

    debug 1, "field creation done, list = (@ftmp)";

    return $self;
}

*fields = \&field;
sub field {
    local $^W = 0;      # -w sucks
    my $self = shift;
    debug 2, "called \$form->field(@_)";

    # Handle any of:
    #
    #   $form->field($name)
    #   $form->field(name => $name, arg => 'val')
    #   $form->field(\@newlist);
    #

    return $self->new(fields => $_[0])
        if ref $_[0] eq 'ARRAY' && @_ == 1;

    my $name = (@_ % 2 == 0) ? '' : shift();
    my %args = cleanargs(@_);
    $args{name} ||= $name;

    # no name - return ala $cgi->param
    unless ($args{name}) {
        # return an array of the names in list context, and a
        # hashref of name/value pairs in a scalar context
        if (wantarray) {
            # list of all field objects
            debug 2, "return (@{$self->{fields}})";
            return @{$self->{fields}};
        } else {
            # this only returns a single scalar value for each field
            return { map { $_ => scalar($_->value) } @{$self->{fields}} };
        }
    }

    # have name, so redispatch to field member
    debug 2, "searching fields for '$args{name}'";
    for (@{$self->{fields}}) {
        debug 2, "checking $_";
        # serial search not that much slower unless dozens of
        # fields, plus then we know it's already been blessed
        if ($_ eq $args{name}) {
            debug 2, "found $_ eq $args{name}";
            delete $args{name};         # segfault??
            return $_->field(%args);    # set args, get value back
        }
    }

    # non-existent field, and no args, so assume we're checking for it
    return unless keys %args > 1;

    # if we're still in here, we need to init a new field
    # push it onto our mail fields array, just like initfields()
    my $f = $self->newfield(%args);
    push @{$self->{fields}}, $f;
    return $f->value;
}

sub newfield {
    my $self = shift;
    my %args = cleanargs(@_);
    puke "Need a name for \$form->newfield()" unless exists $args{name};
    debug 1, "called \$form->newfield($args{name})";

    # extract our per-field options from rearrange
    while (my($from,$to) = each %REARRANGE) {
        next unless exists $self->{$from};
        next if $args{$to};     # manually set
        my $tval;
        my $ref = ref $self->{$from};
        if ($ref && $ref eq 'HASH') {
            $tval = $self->{$from}{$args{name}}; 
        } elsif ($ref && $ref eq 'ARRAY') {
            $tval = ismember($args{name}, @{$self->{$from}}) ? 1 : 0;
        } elsif ($self->{$from} eq 'NONE') {
            $tval = 0;
        } elsif ($self->{$from} eq 'ALL') {
            $tval = 1;
        } else {
            $tval = $self->{$from};
        }
        debug 2, "rearrange: \$args{$to} = $tval;";
        $args{$to} = $tval;
    }

    $args{type} = lc $self->{fieldtype}
        if $self->{fieldtype} && ! exists $args{type};
    if ($self->{fieldattr}) {   # legacy
        while (my($k,$v) = each %{$self->{fieldattr}}) {
            next if exists $args{$k};
            $args{$k} = $v;
        }
    }

    my $f = CGI::FormBuilder::Field->new($self, %args);
    debug 1, "created field $f";
    return $f;   # already set args above ^^^
}

sub basename {
    my $prog = $ENV{SCRIPT_NAME} || $0;
    # Thanks to Randy Kobes for this patch fixing $0 on Win32
    my($basename) = ($^O =~ /Win32/i)
                         ? ($prog =~ m!.*\\(.*)\??!)
                         : ($prog =~ m!.*/(.*)\??!);
    return $basename;
}

sub header {
    my $self = shift;
    $self->{header} = shift if @_;
    return $self->{header} ? "Content-Type: text/html; charset=ISO-8859-1\n\n" : '';
}

sub title {
    my $self = shift;
    $self->{title} = shift if @_;
    return $self->{title} if exists $self->{title};
    return toname($self->basename);
}

sub action {
    my $self = shift;
    $self->{action} = shift if @_;
    return $self->{action} if exists $self->{action};
    return $ENV{SCRIPT_NAME} || $self->basename;
}

sub font {
    my $self = shift;
    $self->{font} = shift if @_;
    return '' unless $self->{font};
    return '' if $self->{stylesheet};   # kill fonts for style

    # Catch for allowable hashref or string
    my $ret;
    if ($self->{font} && ! ref $self->{font}) {
        $ret = { face => $self->{font} };
    } else {
        $ret = $self->{font};
    }
    return wantarray ? %$ret : htmltag('font', %$ret);
}

*tag = \&start;
sub start {
    my $self = shift;
    my %attr = htmlattr('form', %$self);
    $attr{action} ||= $self->action;
    $attr{method} ||= $self->method;
    $attr{class}  ||= $self->{styleclass} . 'form' if $self->{stylesheet};
    return $self->version . htmltag('form', %attr);
}

sub end {
    return '</form>';
}
 
# These return attr in wantarray (unusual) since it helps in render()
sub body {
    my $self = shift;
    $self->{body} = shift if @_;
    return wantarray ? htmlattr('body', $self->{body})
                     : htmltag('body', $self->{body});
}

sub table {
    my $self = shift;
    $self->{table} = shift if @_;
    return '' unless $self->{table};   # 0 or unset
    $self->{table} = {} if $self->{table} == 1;
    $self->{table}{class} ||= $self->{styleclass} . 'table' if $self->{stylesheet};
    return wantarray ? htmlattr('table', $self->{table})
                     : htmltag('table', $self->{table});
}

sub tr {
    my $self = shift;
    $self->{tr} = shift if @_;
    $self->{tr}{class} ||= $self->{styleclass} . 'tr' if $self->{stylesheet};
    return wantarray ? htmlattr('tr', $self->{tr})
                     : htmltag('tr', $self->{tr});
}

sub td {
    my $self = shift;
    $self->{td} = shift if @_;
    $self->{td}{class} ||= $self->{styleclass} . 'td' if $self->{stylesheet};
    return wantarray ? htmlattr('td', $self->{td})
                     : htmltag('td', $self->{td});
}

sub submitted {
    my $self = shift;
    my $smnam = shift || $self->submittedname;  # temp smnam
    my $smtag = $self->{name} ? "${smnam}_$self->{name}" : $smnam;

    if ($self->{params}->param($smtag)) {
        # If we've been submitted, then we return the value of
        # the submit tag (which allows multiple submission buttons).
        # Must use an "|| 0E0" or else hitting "Enter" won't cause
        # $form->submitted to be true (as the button is only sent
        # across CGI when clicked).
        my $sr = $self->{params}->param($self->submitname) || '0E0';
        debug 2, "\$form->submitted() is true, returning $sr";
        return $sr;
    }
    return;
}

sub sessionid {
    my $self = shift;
    return unless $self->sessionidname;
    return $self->{params}->param($self->sessionidname) || '';
}

sub statetags {
    my $self = shift;
    my @state = ();

    # get _submitted
    my $smnam = $self->submittedname;
    my $smtag = $self->{name} ? "${smnam}_$self->{name}" : $smnam;
    my $smv   = $self->{params}->param($smnam) + 1;
    push @state, { name => $smtag, value => $smv, type => 'hidden' };

    # and how about _sessionid
    push @state, { name => $self->sessionidname, value => $self->sessionid,
                   type => 'hidden' };

    return join '', map { htmltag('input', $_) } @state;
}

*keepextra = \&keepextras;
sub keepextras {
    my $self = shift;
    my @keep = ();

    # which ones do they want?
    $self->{keepextras} = shift, return if @_;
    return '' unless $self->{keepextras};

    # If we set keepextras, then this means that any extra fields that
    # we've set that are *not* in our fields() will be added to the form
    my @just_these = ();
    if (my $ref = ref $self->{keepextras}) {
        if ($ref eq 'ARRAY') {
            @just_these = @{$self->{keepextras}};
        } else {
            puke "Unsupported data structure type '$ref' passed to 'keepextras' option";
        }
    }

    # Go thru all params, skipping leading underscore fields and form fields
    for my $p ($self->{params}->param) {
        next if @just_these && ! ismember($p, @just_these);
        next if $p =~ /^_/  || $self->field($p);
        for my $v ($self->{params}->param($p)) {
            # make sure to get all values
            debug 1, "keepextras: saving hidden param $p = $v";
            push @keep, { name => $p, type => 'hidden', value => $v };
        }
    }
    return join '', map { htmltag('input', $_) } @keep;
}


sub javascript {
    my $self = shift;
    $self->{javascript} = shift if @_;

    # auto-determine javascript setting based on user agent
    if ($self->{javascript} eq 'auto') {
        if (exists $ENV{HTTP_USER_AGENT}
                && $ENV{HTTP_USER_AGENT} =~ /lynx|mosaic/i)
        {
            # Turn off for old/non-graphical browsers
            return;
        }
    }
    return $self->{javascript} if exists $self->{javascript};

    # Turn on for all other browsers by default.
    # I suspect this process should be reversed, only
    # showing JavaScript on those browsers we know accept
    # it, but maintaining a full list will result in this
    # module going out of date and having to be updated.
    return 1;
}

sub script {
    local $^W = 0;
    my $self = shift;

    # no state is kept and no args are allowed
    puke "No args allowed for \$form->script" if @_;
    return '' unless $self->javascript;

    # get validate() function name
    my $jsname = $self->{name} ? "$self->{jsname}_$self->{name}" : $self->{jsname};
    my $jsfunc = '';

    # custom user jsfunc option for w/i validate()
    $jsfunc .= $self->jsfunc;

    # expand per-field validation functions
    for ($self->field) {
        $jsfunc .= $_->script;
    }

    # skip out if we have nothing useful
    return '' unless $jsfunc || $self->jshead;

    # prefix with opening code
    $jsfunc = $self->jshead . <<EOJ1 . $jsfunc;
function $jsname (form) {
    var alertstr = '';
    var invalid  = 0;

EOJ1

    # Finally, close our JavaScript if it was opened, wrapping in <script> tags
    # We do a regex trick to turn "%s" into "+invalid+"
    (my $alertstart = $self->{messages}->js_invalid_start) =~ s/%s/'+invalid+'/g;
    (my $alertend   = $self->{messages}->js_invalid_end)   =~ s/%s/'+invalid+'/g;

    $jsfunc .= <<EOJS;
    if (invalid > 0 || alertstr != '') {
        if (! invalid) invalid = 'The following';   // catch for programmer error
        alert('$alertstart'+'\\n\\n'+alertstr+'\\n'+'$alertend');
        // reset counters
        alertstr = '';
        invalid  = 0;
        return false;
    }
    return true;  // all checked ok
}
EOJS

    # setup our form onSubmit
    # needs to be ||= so user can overrride w/ own tag
    # XXX action at a distance, I really don't like this...
    $self->{onSubmit} ||= "return $jsname(this);";

    # set <script> now to the expanded javascript
    return '<script language="JavaScript1.3" type="text/javascript">'
         . "<!-- hide from old browsers\n"
         . $jsfunc 
         . "//-->\n</script>";
}

sub noscript {
    my $self = shift;
    # no state is kept and no args are allowed
    puke "No args allowed for \$form->noscript" if @_;
    return '' unless $self->javascript;
    return '<noscript>' . $self->{messages}->js_noscript . '</noscript>';
}

sub submit {
    my $self = shift;
    $self->{submit} = shift if @_;
    return '' if $self->static || ! $self->{submit};

    # handle the submit button(s)
    # logic is a little complicated - if set but to a false value,
    # then leave off. otherwise use as the value for the tags.
    my @submit = ();
    my $sn = $self->submitname;
    if (ref $self->{submit} eq 'ARRAY') {
        # multiple buttons + JavaScript - dynamically set the _submit value
        my @oncl = $self->{javascript}
                       ? (onClick => "this.form.$sn.value = this.value;") : ();
        for my $s (autodata $self->{submit}) {
            push @submit, { name => $sn, type => 'submit', value => $s, @oncl };
        }
    } else {
        # show the text on the button
        push @submit, { name => $sn, type => 'submit', value => $self->{submit} };
    }
    return join '', map { htmltag('input', $_) } @submit;
}

sub reset {
    my $self = shift;
    $self->{reset} = shift if @_;
    return '' if $self->static || ! $self->{reset};

    # similar to submit(), but a little simpler ;-)
    my $reset = { type => 'reset', name => $self->resetname, value => $self->{reset} };
    return htmltag('input', $reset);
}

sub text {
    my $self = shift;
    $self->{text} = shift if @_;
    
    # having any required fields changes the leading text
    my $req = 0;
    my $inv = 0;
    for ($self->fields) {
        $req++ if $_->required;
        $inv++ if $_->invalid;  # failed validate()
    }

    unless ($self->static) {
        # only show either invalid or required text
        return $self->{text} . sprintf($self->{messages}->form_invalid_text,
                                       $self->{messages}->form_invalid_opentag,
                                       $self->{messages}->form_invalid_closetag) if $inv;
        return $self->{text} . sprintf($self->{messages}->form_required_text,
                                       $self->{messages}->form_required_opentag,
                                       $self->{messages}->form_required_closetag) if $req;
    }
    return $self->{text};
}

sub cgi_param {
    my $self = shift;
    $self->{params}->param(@_);
}

sub tmpl_param {
    puke "To interface with tmpl_param(), you must now create your own object";
}

sub version {
    # Hidden trailer. If you perceive this as annoying, let me know and I
    # may remove it. It's supposed to help.
    return '' if $::TESTING;
    if (ref $_[0]) {
        return "\n<!-- Generated by CGI::FormBuilder v$VERSION available from www.formbuilder.org -->\n";
    } else {
        return "CGI::FormBuilder v$VERSION by Nathan Wiger. All Rights Reserved.\n";
    }
}

sub values {
    my $self = shift;

    if (@_) {
        $self->{values} = cleanargs(@_);
        my %val = ();
        my @val = ();

        # We currently make two passes, first getting the values
        # and storing them into a temp hash, and then going thru
        # the fields and picking up the values and attributes.
        local $" = ',';
        debug 1, "\$form->{values} = ($self->{values})";

        my $ref = ref $self->{values};
        if ($ref && $ref eq 'CODE') {
            # it's a sub; lookup each value in turn
            for my $key (&{$self->{values}}) {
                # always assume an arrayref of values...
                $val{$key} = [ &{$self->{values}}($key) ];
                debug 2, "setting values from \\&code(): $key = (@{$val{$key}})";
            }
        } elsif ($ref && $ref eq 'HASH') {
            # must lc all the keys since we're case-insensitive, then
            # we turn our values hashref into an arrayref on the fly
            my @v = autodata $self->{values};
            while (@v) {
                my $key = lc shift @v;
                $val{$key} = [ autodata shift @v ];
                debug 2, "setting values from HASH: $key = (@{$val{$key}})";
            }
        } elsif ($ref && $ref eq 'ARRAY') {
            # also accept an arrayref which is walked sequentially below
            debug 2, "setting values from ARRAY: (walked below)";
            @val = autodata $self->{values};
        } else {
            puke "Unsupported operand to 'values' option - must be \\%hash, \\&sub, or \$object";
        }

        # redistribute values across all existing fields
        for ($self->fields) {
            my $v = $val{lc($_)} || shift @val;     # use array if no value
            $_->field(value => $v) if defined $v;
        }
    }

}

sub nameopts {
    my $self = shift;
    if (@_) {
        $self->{nameopts} = shift;
        for ($self->fields) {
            $_->field(nameopts => $self->{nameopts});
        }
    }
    return $self->{nameopts};
}

sub sortopts {
    my $self = shift;
    if (@_) {
        $self->{sortopts} = shift;
        for ($self->fields) {
            $_->field(sortopts => $self->{sortopts});
        }
    }
    return $self->{sortopts};
}

sub selectnum {
    my $self = shift;
    if (@_) {
        $self->{selectnum} = shift;
        for ($self->fields) {
            $_->field(selectnum => $self->{selectnum});
        }
    }
    return $self->{selectnum};
}

sub options {
    my $self = shift;
    if (@_) {
        $self->{options} = cleanargs(@_);
        my %val = ();

        # same case-insensitization as $form->values
        my @v = autodata $self->{options};
        while (@v) {
            my $key = lc shift @v;
            $val{$key} = [ autodata shift @v ];
        }

        for ($self->fields) {
            my $v = $val{lc($_)};
            $_->field(options => $v) if defined $v;
        }
    }
    return $self->{options};
}

sub labels {
    my $self = shift;
    if (@_) {
        $self->{labels} = cleanargs(@_);
        my %val = ();

        # same case-insensitization as $form->values
        my @v = autodata $self->{labels};
        while (@v) {
            my $key = lc shift @v;
            $val{$key} = [ autodata shift @v ];
        }

        for ($self->fields) {
            my $v = $val{lc($_)};
            $_->field(label => $v) if defined $v;
        }
    }
    return $self->{labels};
}

# Note that validate does not work like a true accessor
sub validate {
    my $self = shift;
    if (@_) {
        $self->{validate} = ref $_[0] ? shift : { @_ };
    }
    my $ok = 1;
    debug 1, "validating all fields via \$form->validate";
    for ($self->fields) {
        $ok = 0 unless $_->validate;
    }
    debug 1, "validation done, ok = $ok (should be 1)";
    return $ok;
}

sub confirm {
    # This is nothing more than a special wrapper around render()
    my $self = shift;
    my $date = $::TESTING ? 'LOCALTIME' : localtime();
    $self->{text} ||= sprintf $self->{messages}->form_confirm_text, $date;
    $self->{static} = 1;
    return $self->render(@_);
}   

sub render {
    local $^W = 0;        # -w sucks
    my $self = shift;
    my $sub  = $self->{render};

    debug 1, "starting \$form->render(@_)";

    # any arguments are used to make permanent changes to the $form
    if (@_) {
        puke "Odd number of arguments passed into \$form->render()"
            unless @_ % 2 == 0;
        while (@_) {
            my $k = shift;
            $self->$k(shift);
        }
    }

    # check for engine type
    my $mod;
    my $ref = ref $self->{template};
    if (! $ref && $self->{template}) {
        # "legacy" string filename for HTML::Template; redo format
        # modifying $self object is ok because it's compatible
        $self->{template} = {
            type     => 'HTML',
            filename => $self->{template},
        };
        $ref = 'HASH';  # tricky
        debug 2, "rewrote 'template' option since found filename";
    }

    my %opt;
    if ($ref eq 'HASH') {
        # must copy to avoid destroying
        %opt = %{ $self->{template} };
        $mod = delete $opt{type} || 'HTML';
    } elsif ($ref eq 'CODE') {
        # subroutine wrapper
        return &{$self->{template}}($self);
    } elsif (UNIVERSAL::can($self->{template}, $sub)) {
        # instantiated object
        return $self->{template}->$sub($self);
    } elsif ($ref) {
        puke "Unsupported operand to 'template' option - must be \\%hash, \\&sub, or \$object w/ render()";
    }

    # load user-specified rendering module if supplied
    if ($mod) {
        # user can give 'Their::Complete::Module' or an 'IncludedTemplate'
        $mod = join '::', __PACKAGE__, 'Template', $mod unless $mod =~ /::/;
        debug 1, "loading $mod for 'template' option";

        eval "require $mod";
        puke "Bad template engine $mod: $@" if $@;

        # dispatch to user sub
        debug 2, "return &{$mod\::$sub}($self)";

        no strict 'refs';
        return &{"$mod\::$sub"}($self, %opt);

    } else {

        # Builtin default rendering (follows)
        my $html = '';
        debug 1, "no template module specified, using builtin rendering";

        # Just for test suite purposes
        $self->{doctype} = '<html>' if $::TESTING;

        # Opening CGI/title gunk 
        if ($self->header) {
            $html .= $self->header;
            $html .= $self->doctype . '<head>';
            $html .= '<title>' . $self->title . '</title>' if $self->title;

            # stylesheet path if specified
            if ($self->stylesheet && $self->stylesheet =~ /\D/) {
                $html .= htmltag('link', { rel => 'stylesheet', href => $self->stylesheet });
            }
        }

        # JavaScript validate/head functions
        if (my $sc = $self->script) {
            $html .= "\n" if $html;
            $html .= $sc . $self->noscript;
        }

        # Opening HTML if so requested
        my $font = $self->font;
        if ($self->header) {
            $html .= "</head>\n";
            $html .= $self->body;
            $html .= $font;
            $html .= '<h3>' . $self->title . '</h3>' if $self->title;
        }

        # Begin form
        $html .= $self->text;
        $html .= $self->start . $self->statetags . $self->keepextras;

        # Render hidden fields first
        my @unhidden;
        for my $field ($self->field) {
            push(@unhidden, $field), next if $field->type ne 'hidden';
            $html .= $field->tag;   # no label/etc for hidden fields
        }

        # Get table stuff and reused calls
        my $table = $self->table;
        my $tr    = $self->tr;
        my $td    = $self->td;
        $html .= $table . "\n";     # want newline regardless

        my %ta = $self->td;
        $ta{align} = 'left';    # force input tags left
        my $lh = htmltag('td', %ta);

        # Render regular fields in table
        for my $field (@unhidden) {
            debug 2, "render: attacking normal field '$field'";
            if ($table) {
                $html .= $tr . $td . $font;
                $html .= $self->{messages}->form_required_opentag  if $field->required;
                $html .= $field->label;
                $html .= $self->{messages}->form_required_closetag if $field->required;
                $html .= '</font>' if $font;
                $html .= '</td>' . $lh . $font;
                $html .= $field->tag;
                $html .= ' ' . $field->comment if $field->comment;  # "if" to control ' '
                $html .= '</font>' if $font;
                $html .= '</td>';
                $html .= $lh . $field->message . '</td>' if $field->invalid;
                $html .= "</tr>\n";
            } else {
                $html .= $field->label . ' ' . $field->tag . ' ';
                $html .= '<br />' if $self->linebreaks;
            }
        }

        # Throw buttons in a colspan
        my $buttons = $self->reset . $self->submit;
        if ($buttons) {
            if ($table) {
                $ta{colspan} = 2;
                $ta{align} = 'center';
                $html .= $self->tr . htmltag('td', %ta) . $font;
            }
            $html .= $buttons;
            if ($table) {
                $html .= '</font>' if $font;
                $html .= "</td></tr>\n" if $table;
            }
        }

        # Properly nest closing tags
        $html .= '</table>' if $table;
        $html .= '</form>';     # should be $form->end
        $html .= '</font>'  if $font && $self->header;
        $html .= "</body></html>" if $self->header;
        $html .= "\n";

        return $html;
    }
}

# These routines should be moved to ::Mail or something since they're never used
sub mail () {
    # This is a very generic mail handler
    my $self = shift;
    my %args = cleanargs(@_);

    # Where does the mailer live? Must be sendmail-compatible
    my $mailer = undef;
    unless ($mailer = $args{mailer} && -x $mailer) {
        for my $sendmail (qw(/usr/lib/sendmail /usr/sbin/sendmail /usr/bin/sendmail)) {
            if (-x $sendmail) {
                $mailer = "$sendmail -t";
                last;
            }
        }
    }
    unless ($mailer) {
        belch "Cannot find a sendmail-compatible mailer to use; mail aborting";
        return;
    }
    unless ($args{to}) {
        belch "Missing required 'to' argument; cannot continue without recipient";
        return;
    }

    debug 1, "opening new mail to $args{to}";

    # untaint
    my $oldpath = $ENV{PATH};
    $ENV{PATH} = '/usr/bin:/usr/sbin';

    open(MAIL, "|$mailer >/dev/null 2>&1") || next;
    print MAIL "From: $args{from}\n";
    print MAIL "To: $args{to}\n";
    print MAIL "Cc: $args{cc}\n" if $args{cc};
    print MAIL "Subject: $args{subject}\n\n";
    print MAIL "$args{text}\n";

    # retaint
    $ENV{PATH} = $oldpath;

    return close(MAIL);
}

sub mailconfirm () {

    # This prints out a very generic message. This should probably
    # be much better, but I suspect very few if any people will use
    # this method. If you do, let me know and maybe I'll work on it.

    my $self = shift;
    my $to = shift unless (@_ > 1);
    my %args = cleanargs(@_);

    # must have a "to"
    return unless $args{to} ||= $to;

    # defaults
    $args{from}    ||= 'auto-reply';
    $args{subject} ||= sprintf $self->{messages}->mail_confirm_subject, $self->title;
    $args{text}    ||= sprintf $self->{messages}->mail_confirm_text, scalar localtime();

    debug 1, "mailconfirm() called, subject = '$args{subject}'";

    $self->mail(%args);
}

sub mailresults () {
    # This is a wrapper around mail() that sends the form results
    my $self = shift;
    my %args = cleanargs(@_);

    # Get the field separator to use
    my $delim = $args{delimiter} || ': ';
    my $join  = $args{joiner}    || $";
    my $sep   = $args{separator} || "\n";

    # subject default
    $args{subject} ||= sprintf $self->{messages}->mail_results_subject, $self->title;
    debug 1, "mailresults() called, subject = '$args{subject}'";

    if ($args{skip}) {
        if ($args{skip} =~ m#^m?(\S)(.*)\1$#) {
            ($args{skip} = $2) =~ s/\\\//\//g;
            $args{skip} =~ s/\//\\\//g;
        }
    }

    my @form = ();
    for my $field ($self->fields) {
        if ($args{skip} && $field =~ /$args{skip}/) {
            next;
        }
        my $v = join $join, $field->value;
        $field = $field->label if $args{labels};
        push @form, "$field$delim$v"; 
    }
    my $text = join $sep, @form;

    $self->mail(%args, text => $text);
}

sub DESTROY { 1 }

# This is used to access all options after new(), by name
sub AUTOLOAD {
    # This allows direct addressing by name
    my $self = shift;
    my($name) = $AUTOLOAD =~ /.*::(.+)/;

    debug 3, "-> dispatch to \$form->{$name} = @_";
    $self->{$name} = shift if @_;

    # Try to catch outdated $form->$fieldname usage
    if ((! exists($self->{$name}) || @_)
      && ! $CGI::FormBuilder::Util::OURATTR{$name}) {
        belch "Possible outdated field access via \$form->$name()"
    }

    return $self->{$name};
}

1;

__END__

=head1 DESCRIPTION

If this is your first time using B<FormBuilder>, you should check out
the website for tutorials and examples:

    www.formbuilder.org

You should also consider joining the mailing list by sending an email to:

    fbusers-subscribe@formbuilder.org

For a fast description of all available options, search for the string 
"quick" in this document.

=head2 Overview

I hate generating and processing forms. Hate it, hate it, hate it,
hate it. My forms almost always end up looking the same, and almost
always end up doing the same thing. Unfortunately, there haven't
really been any tools out there that streamline the process. Many
modules simply substitute Perl for HTML code:

    # The manual way
    print qq(<input name="email" type="text" size="20">);

    # The module way
    print input(-name => 'email', -type => 'text', -size => '20');

The problem is, that doesn't really gain you anything - you still
have just as much code. Modules like C<CGI.pm> are great for
decoding parameters, but they don't save you much time when trying
to generate and process forms.

The goal of C<CGI::FormBuilder> (B<"FormBuilder">) is to provide an easy
way for you to generate and process entire CGI form-based applications.
Its main features are:

=over

- Lots of builtin "intelligence", giving about a 4:1 ratio of the
code it generates versus what you have to write.

- Automatic field typing based on the number of options, as well
as auto-naming and auto-layout.

- Full-blown regex validation for form fields, including some builtin
patterns and even JavaScript code generation.

- Native HTML generation that is XHTML compliant and pretty nice
looking, honestly.

- Builtin support for C<HTML::Template>, C<Text::Template>, and
C<Template Toolkit> so you can tweak the HTML any way you want.

=back

=head2 Walkthrough

Let's walk through a whole example to see how B<FormBuilder> works.
We'll start with this, which is actually a complete (albeit simple)
form application:

    use CGI::FormBuilder;

    my @fields = qw(name email password confirm_password zipcode);

    my $form = CGI::FormBuilder->new(
                    fields => \@fields,
                    header => 1
               );

    print $form->render;

The above code will render an entire form, and take care of maintaining
state across submissions. But it doesn't really I<do> anything useful
at this point.

So to start, let's add the C<validate> option to make sure the data
entered is valid:

    my $form = CGI::FormBuilder->new(
                    fields   => \@fields, 
                    header   => 1,
                    validate => {
                       name  => 'NAME',
                       email => 'EMAIL'
                    }
               );

We now get a whole bunch of JavaScript validation code, and the
appropriate hooks are added so that the form is validated by the
browser C<onSubmit> as well.

Now, we also want to validate our form on the server side, since
the user may not be running JavaScript. All we do is add the
statement:

    $form->validate;

Which will go through the form, checking each field specified to
the C<validate> option to see if it's ok. If there's a problem, then
that field is highlighted, so that when you print it out the errors
will be apparent.

Of course, the above returns a truth value, which we should use to
see if the form was valid. That way, we only update our database if
everything looks good:

    if ($form->validate) {
        # print confirmation screen
        print $form->confirm;
    } else {
        # print the form for them to fill out
        print $form->render;
    }

However, we really only want to do this after our form has been
submitted, since otherwise this will result in our form showing
errors even though the user hasn't gotten a chance to fill it
out yet. As such, we want to check for whether the form has been
C<submitted()> yet:

    if ($form->submitted && $form->validate) {
        # print confirmation screen
        print $form->confirm;
    } else {
        # print the form for them to fill out
        print $form->render;
    }

Now that know that our form has been submitted and is valid, we
need to get our values. To do so, we use the C<field()> method
along with the name of the field we want:

    my $email = $form->field(name => 'email');

Note we can just specify the name of the field if it's the only
option:

    my $email = $form->field('email');   # same thing

As a very useful shortcut, we can get all our fields back as a
hashref of field/value pairs by calling C<field()> with no arguments:

    my $fields = $form->field;      # all fields as hashref

To make things easy, we'll use this form so that we can pass it
easily into a sub of our choosing:

    if ($form->submitted && $form->validate) {
        # form was good, let's update database
        my $fields = $form->field;

        # update database (you write this part)
        do_data_update($fields); 

        # print confirmation screen
        print $form->confirm;
    }

Finally, let's say we decide that we like our form fields, but we
need the HTML to be laid out very precisely. No problem! We simply
create an C<HTML::Template> compatible template and tell B<FormBuilder>
to use it. Then, in our template, we include a couple special tags
which B<FormBuilder> will automatically expand:

    <html>
    <head>
    <title><tmpl_var form-title></title>
    <tmpl_var js-head><!-- this holds the JavaScript code -->
    </head>
    <tmpl_var form-start><!-- this holds the initial form tag -->
    <h3>User Information</h3>
    Please fill out the following information:
    <!-- each of these tmpl_var's corresponds to a field -->
    <p>Your full name: <tmpl_var field-name>
    <p>Your email address: <tmpl_var field-email>
    <p>Choose a password: <tmpl_var field-password>
    <p>Please confirm it: <tmpl_var field-confirm_password>
    <p>Your home zipcode: <tmpl_var field-zipcode>
    <p>
    <tmpl_var form-submit><!-- this holds the form submit button -->
    </form><!-- can also use "tmpl_var form-end", same thing -->

Then, all we need to do add the C<template> option, and the rest of
the code stays the same:

    my $form = CGI::FormBuilder->new(
                    fields   => \@fields, 
                    header   => 1,
                    validate => {
                       name  => 'NAME',
                       email => 'EMAIL'
                    },
                    template => 'userinfo.tmpl'
               );

So, our complete code thus far looks like this:

    use CGI::FormBuilder;

    my @fields = qw(name email password confirm_password zipcode);

    my $form = CGI::FormBuilder->new(
                    fields   => \@fields, 
                    header   => 1,
                    validate => {
                       name  => 'NAME',
                       email => 'EMAIL'
                    },
                    template => 'userinfo.tmpl',
               );

    if ($form->submitted && $form->validate) {
        # form was good, let's update database
        my $fields = $form->field;

        # update database (you write this part)
        do_data_update($fields); 

        # print confirmation screen
        print $form->confirm;

    } else {
        # print the form for them to fill out
        print $form->render;
    }

You may be surprised to learn that for many applications, the
above is probably all you'll need. Just fill in the parts that
affect what you want to do (like the database code), and you're
on your way.

B<Note:> If you are confused at all by the backslashes you see
in front of some data pieces above, such as C<\@fields>, skip down
to the brief section entitled L</"REFERENCES"> at the bottom of this
document (it's short).

=head1 METHODS

This documentation is very extensive, but can be a bit dizzying due
to the enormous number of options that let you tweak just about anything.
As such, I recommend that you stop and visit:

    www.formbuilder.org

And click on "Tutorials" and "Examples". Then, use the following section
as a reference later on.

=head2 new()

This method creates a new C<$form> object, which you then use to generate
and process your form. In the very shortest version, you can just specify
a list of fields for your form:

    my $form = CGI::FormBuilder->new(
                    fields => [qw(first_name birthday favorite_car)]
               );

Any of the options below, in addition to being specified to C<new()>, can
also be manipulated directly with a method of the same name. For example,
to change the C<header> and C<stylesheet> options, either of these works:

    # Way 1
    my $form = CGI::FormBuilder->new(
                    fields => \@fields,
                    header => 1,
                    stylesheet => '/path/to/style.css',
               );

    # Way 2
    my $form = CGI::FormBuilder->new(
                    fields => \@fields
               );
    $form->header(1);
    $form->stylesheet('/path/to/style.css');

The second form is useful if you want to wrap certain options in
conditionals:

    if ($have_template) {
        $form->header(0);
        $form->template('template.tmpl');
    } else {
        $form->header(1);
        $form->stylesheet('/path/to/style.css');
    }

Here is a quick list of C<new()> options, organized by use:

    my $form = CGI::FormBuilder->new(
                    # important options
                    fields     => \@array | \%hash,
                    header     => 0 | 1,
                    method     => 'POST' | 'GET',
                    name       => $string,
                    reset      => 0 | $string,
                    submit     => 0 | $string | \@array,
                    text       => $text,
                    required   => \@array | 'ALL' | 'NONE',
                    values     => \%hash | \@array,
                    validate   => \%hash,

                    # lesser-used options
                    action     => $script,
                    debug      => 0 | 1 | 2 | 3,
                    keepextras => 0 | 1 | \@array,
                    params     => $object,
                    messages   => $filename | \%hash | $object,
                    sticky     => 0 | 1,
                    template   => $filename | \%hash | $object | \&sub,
                    title      => $title,

                    # formatting options
                    body       => \%attr,
                    fieldtype  => 'type',
                    fieldattr  => \%attr,
                    font       => $font | \%attr,
                    javascript => 0 | 1,
                    jshead     => $jscode,
                    jsfunc     => $jscode,
                    labels     => \%hash,     # use field() instead
                    linebreaks => 0 | 1,
                    options    => \%hash,     # use field() instead
                    selectnum  => $threshold,
                    smartness  => 0 | 1 | 2,
                    sortopts   => 'NAME' | 'NUM' | 1 | \&sub,
                    static     => 0 | 1,      # use confirm() instead
                    styleclass => $string,
                    stylesheet => 0 | 1 | $path,
                    table      => 0 | 1 | \%attr,
                    td         => \%attr,     # use a template or
                    tr         => \%attr,     # stylesheet instead
                );

The following is a description of each option, in alphabetical order:

=over

=item action => $script

What script to point the form to. Defaults to itself, which is
the recommended setting.

=item body => \%attr

This takes a hashref of attributes that will be stuck in the
C<< <body> >> tag verbatim (for example, bgcolor, alink, etc).
See the C<fieldattr> tag for more details, and also the
C<template> option.

=item debug => 0 | 1 | 2 | 3

If set to 1, the module spits copious debugging info to STDERR.
If set to 2, it spits out even more gunk. 3 is too much. Defaults to 0.

=item fields => \@array | \%hash

As shown above, the C<fields> option takes an arrayref of fields to use
in the form. The fields will be printed out in the same order they are
specified. This option is needed if you expect your form to have any fields,
and is I<the> central option to FormBuilder.

You can also specify a hashref of key/value pairs. The advantage is
you can then bypass the C<values> option. However, the big disadvantage
is you cannot control the order of the fields. This is ok if you're
using a template, but in real-life it turns out that passing a hashref
to C<fields> is not very useful.

=item fieldtype => 'type'

This can be used to set the default type for all fields in the form.
You can then override it on a per-field basis using the C<field()> method.

=item fieldattr => \%attr

Even more flexible than C<fieldtype>, this option allows you to 
specify I<any> HTML attribute and have it be the default for all
fields. This used to be good for stylesheets, but now that there
is a C<stylesheet> option, this is fairly useless.

=item font => $font | \%attr

The font face to use for the form. This is output as a series of
C<< <font> >> tags for best browser compatibility, and will even
properly nest them in all of the table elements. If you specify
a hashref instead of just a font name, then each key/value pair
will be taken as part of the C<< <font> >> tag:

    font => {face => 'verdana', size => '-1', color => 'gray'}

That becomes:

    <font face="verdana" size="-1" color="gray">

I use this option all the time. 

=item header => 0 | 1

If set to 1, a valid C<Content-type> header will be printed out,
along with a whole bunch of HTML C<< <body> >> code, a C<< <title> >>
tag, and so on. This defaults to 0, since often people end up using
templates or embedding forms in other HTML.

=item javascript => 0 | 1

If set to 1, JavaScript is generated in addition to HTML, the
default setting.

=item jshead => $jscode

If using JavaScript, you can also specify some JavaScript code
that will be included verbatim in the <head> section of the
document. I'm not very fond of this one, what you probably
want is the next option.

=item jsfunc => $jscode

Just like C<jshead>, only this is stuff that will go into the
C<validate> JavaScript function. As such, you can use it to
add extra JavaScript validate code verbatim. If something fails,
you should do two things:

    1. append to the JavaScript variable "alertstr"
    2. increment the JavaScript variable "invalid"

For example:

    my $jsfunc = <<EOJS;
      if (form.password.value == 'password') {
        alertstr += "Moron, you can't use 'password' for your password!\\n";
        invalid++;
      }
    EOJS

    my $form = CGI::FormBuilder->new(... jsfunc => $jsfunc);

Then, this code will be automatically called when form validation
is invoked. I find this option can be incredibly useful. Most often,
I use it to bypass validation on certain submit modes. The submit
button that was clicked is C<form._submit.value>:

    my $jsfunc = <<EOJS;
      if (form._submit.value == 'Delete') {
        if (confirm("Really DELETE this entry?")) return true;
        return false;
      } else if (form._submit.value == 'Cancel') {
        // skip validation since we're cancelling
        return true;
      }
    EOJS

Important: When you're quoting, remember that Perl will expand "\n"
itself. So, if you want a literal newline, you must double-escape
it, as shown above.

=item keepextras => 0 | 1 | \@array

If set to 1, then extra parameters not set in your fields declaration
will be kept as hidden fields in the form. However, you will need
to use C<cgi_param()>, B<NOT> C<field()>, to get to the values.

This is useful if you want to keep some extra parameters like mode or
company available but not have them be valid form fields:

    keepextras => 1

That will preserve any extra params. You can also specify an arrayref,
in which case only params in that list will be preserved. For example:

    keepextras => [qw(mode company)]

Will only preserve the params C<mode> and C<company>.

=item labels => \%hash

Like C<values>, this is a list of key/value pairs where the keys
are the names of C<fields> specified above. By default, B<FormBuilder>
does some snazzy case and character conversion to create pretty labels
for you. However, if you want to explicitly name your fields, use this
option.

For example:

    my $form = CGI::FormBuilder->new(
                    fields => [qw(name email)],
                    labels => {
                        name  => 'Your Full Name',
                        email => 'Primary Email Address'
                    }
               );

Usually you'll find that if you're contemplating this option what
you really want is a template.

=item linebreaks => 0 | 1

If set to 1, line breaks will be inserted after each input field.
By default this is figured out for you, so usually not needed.

=item method => 'POST' | 'GET'

The type of CGI method to use, either C<POST> or C<GET>. Defaults
to C<GET> if nothing is specified. Note that for forms that cause
changes on the server, such as database inserts, you should use
the C<POST> method.

=item messages => $filename | \%hash | $object

This option overrides the default B<FormBuilder> messages in order to
provide multilingual support (or just different text for the picky ones).
For details on this option, please refer to L<CGI::FormBuilder::Messages>.

=item name => $string

This names the form. It is optional, but when used, it renames several
key variables and functions according to the name of the form. This
allows you to (a) use multiple forms in a sequential application and
(b) display multiple forms inline in one document. If you're trying
to build a complex multi-form app and are having problems, try naming
your forms.

=item options => \%hash

This is one of several I<meta-options> that allows you to specify
stuff for multiple fields at once:

    my $form = CGI::FormBuilder->new(
                    fields => [qw(part_number department in_stock)],
                    options => {
                        department => [qw(hardware software)],
                        in_stock   => [qw(yes no)],
                    }
               );

This has the same effect as using C<field()> for the C<department>
and C<in_stock> fields to set options individually.

=item params => $object

This specifies an object from which the parameters should be derived.
The object must have a C<param()> method which will return values
for each parameter by name. By default a CGI object will be 
automatically created and used.

However, you will want to specify this if you're using C<mod_perl>:

    use Apache::Request;
    use CGI::FormBuilder;

    sub handler {
        my $r = Apache::Request->new(shift);
        my $form = CGI::FormBuilder->new(... params => $r);
        print $form->render;
    }

Or, if you need to initialize a C<CGI.pm> object separately and
are using a C<POST> form method:

    use CGI;
    use CGI::FormBuilder;

    my $q = new CGI;
    my $form = CGI::FormBuilder->new(... params => $q);

Usually you don't need to do this, unless you need to access other
parameters outside of B<FormBuilder>'s control.

=item required => \@array | 'ALL' | 'NONE'

This is a list of those values that are required to be filled in.
Those fields named must be included by the user. If the C<required>
option is not specified, by default any fields named in C<validate>
will be required.

In addition, the C<required> option also takes two other settings,
the strings C<ALL> and C<NONE>. If you specify C<ALL>, then all
fields are required. If you specify C<NONE>, then none of them are
I<in spite of what may be set via the "validate" option>.

This is useful if you have fields that are optional, but that you
want to be validated if filled in:

    my $form = CGI::FormBuilder->new(
                    fields => qw[/name email/],
                    validate => { email => 'EMAIL' },
                    required => 'NONE'
               );

This would make the C<email> field optional, but if filled in then
it would have to match the C<EMAIL> pattern.

In addition, it is I<very> important to note that if the C<required>
I<and> C<validate> options are specified, then they are taken as an
intersection. That is, only those fields specified as C<required>
must be filled in, and the rest are optional. For example:

    my $form = CGI::FormBuilder->new(
                    fields => qw[/name email/],
                    validate => { email => 'EMAIL' },
                    required => [qw(name)]
               );

This would make the C<name> field mandatory, but the C<email> field
optional. However, if C<email> is filled in, then it must match the
builtin C<EMAIL> pattern.

=item reset => 0 | $string

If set to 0, then the "Reset" button is not printed. If set to 
text, then that will be printed out as the reset button. Defaults
to printing out a button that says "Reset".

=item selectnum => $threshold

This detects how B<FormBuilder>'s auto-type generation works. If a
given field has options, then it will be a radio group by default.
However, if more than C<selectnum> options are present, then it will
become a select list. The default is 5 or more options. For example:

    # This will be a radio group
    my @opt = qw(Yes No);
    $form->field(name => 'answer', options => \@opt);

    # However, this will be a select list
    my @states = qw(AK CA FL NY TX);
    $form->field(name => 'state', options => \@states);

    # Single items are checkboxes (allows unselect)
    $form->field(name => 'answer', options => ['Yes']);

There is no threshold for checkboxes since, if you think about it,
they are really a multi-radio select group. As such, a radio group
becomes a checkbox group if the C<multiple> option is specified and
the field has I<less> than C<selectnum> options. Got it?

=item smartness => 0 | 1 | 2

By default CGI::FormBuilder tries to be pretty smart for you, like
figuring out the types of fields based on their names and number
of options. If you don't want this behavior at all, set C<smartness>
to C<0>. If you want it to be B<really> smart, like figuring
out what type of validation routines to use for you, set it to
C<2>. It defaults to C<1>.

=item sortopts => 'NAME' | 'NUM' | 1 | \&sub

If specified to C<new()>, this has the same effect as the same-named
option to C<field()>, only it applies to all fields.

=item static => 0 | 1

If set to 1, then the form will be output with static hidden fields.
Defaults to 0. Normally not useful; use C<confirm()> instead.

=item sticky => 0 | 1

Determines whether or not form values should be sticky across
submissions. This defaults to 1, meaning values are sticky. However,
you may want to set it to 0 if you have a form which does something
like adding parts to a database. See the L</"EXAMPLES"> section for 
a good example.

=item submit => 0 | $string | \@array

If set to 0, then the "Submit" button is not printed. It defaults
to creating a button that says "Submit" verbatim. If given an
argument, then that argument becomes the text to show. For example:

    print $form->render(submit => 'Do Lookup');

Would make it so the submit button says "Do Lookup" on it. 

If you pass an arrayref of multiple values, you get a key benefit.
This will create multiple submit buttons, each with a different value.
In addition, though, when submitted only the one that was clicked
will be sent across CGI via some JavaScript tricks. So this:

    print $form->render(submit => ['Add A Gift', 'No Thank You']);

Would create two submit buttons. Clicking on either would submit the
form, but you would be able to see which one was submitted via the
C<submitted()> function:

    my $clicked = $form->submitted;

So if the user clicked "Add A Gift" then that is what would end up
in the variable C<$clicked> above. This allows nice conditionality:

    if ($form->submitted eq 'Add A Gift') {
        # show the gift selection screen
    } elsif ($form->submitted eq 'No Thank You')
        # just process the form
    }

See the L</"EXAMPLES"> section for more details.

=item styleclass => $string

This string is prefixed to stylesheet class names. See below.

=item stylesheet => 0 | 1 | $path

This option turns on stylesheets in the HTML output by B<FormBuilder>.
Each element is prefixed by whatever C<styleclass> is set to ("fb_"
by default). It is up to you to provide the actual style definitions.
If you provide a C<$path> rather than just a 1/0 toggle, then that
C<$path> will be included in a C<< <link> >> tag as well.

=item table => 0 | 1 | \%tabletags

By default B<FormBuilder> decides how to layout the form based on
the number of fields, values, etc. You can force it into a table
by specifying C<1>, or force it out of one with C<0>.

If you specify a hashref instead, then these will be used to 
create the C<< <table> >> tag. For example, to create a table
with no cellpadding or cellspacing, use:

    table => {cellpadding => 0, cellspacing => 0}

Also, you can specify options to the C<< <td> >> and C<< <tr> >>
elements as well in the same fashion.

=item template => $filename | \%hash | \&sub | $object

This points to a filename that contains an C<HTML::Template>
compatible template to use to layout the HTML. You can also specify
the C<template> option as a reference to a hash, allowing you to
further customize the template processing options, or use other
template engines.

If C<template> points to a sub reference, that routine is called
and its return value directly returned. If it is an object, then
that object's C<render()> routine is called and its value returned.

For lots more information, please see L<CGI::FormBuilder::Template>.

=item text => $text

This is text that is included below the title but above the
actual form. Useful if you want to say something simple like
"Contact $adm for more help", but if you want lots of text
check out the C<template> option above.

=item title => $title

This takes a string to use as the title of the form. 

=item values => \%hash | \@array

The C<values> option takes a hashref of key/value pairs specifying
the default values for the fields. These values will be overridden
by the values entered by the user across the CGI. The values are
used case-insensitively, making it easier to use DBI hashref records
(which are in upper or lower case depending on your database).

This option is useful for selecting a record from a database or
hardwiring some sensible defaults, and then including them in the
form so that the user can change them if they wish. For example:

    my $rec = $sth->fetchrow_hashref;
    my $form = CGI::FormBuilder->new(fields => \@fields,
                                     values => $rec);

You can also pass an arrayref, in which case each value is used
sequentially for each field as specified to the C<fields> option.

=item validate => \%hash

This option takes a hashref of key/value pairs. Each key is the
name of a field from the C<fields> option, or the string C<ALL>
in which case it applies to all fields. Each value is one of
the following:

    - a regular expression in 'quotes' to match against
    - an arrayref of values, of which the field must be one
    - a string that corresponds to one of the builtin patterns
    - a string containing a literal code comparison to do
    - a reference to a sub to be used to validate the field
      (the sub will receive the value to check as the first arg)

In addition, each of these can also be grouped together as:

    - a hashref containing pairings of comparisons to do for
      the two different languages, "javascript" and "perl"

By default, the C<validate> option also toggles each field to make
it required. However, you can use the C<required> option to change
this, see it for more details.

Let's look at a concrete example:

    my $form = CGI::FormBuilder->new(
                    fields => [
                        qw(username password confirm_password
                           first_name last_name email)
                    ],
                    validate => {
                        username   => [qw(nate jim bob)],
                        first_name => '/^\w+$/',    # note the 
                        last_name  => '/^\w+$/',    # single quotes!
                        email      => 'EMAIL',
                        password   => \&check_password,
                        confirm_password => {
                            javascript => '== form.password.value',
                            perl       => 'eq $form->field("password")'
                        },
                    },
               );

    # simple sub example to check the password
    sub check_password ($) {
        my $v = shift;                   # first arg is value
        return unless $v =~ /^.{6,8}/;   # 6-8 chars
        return if $v eq "password";      # dummy check
        return unless passes_crack($v);  # you write "passes_crack()"
        return 1;                        # success
    }

This would create both JavaScript and Perl routines on the fly
that would ensure:

    - "username" was either "nate", "jim", or "bob"
    - "first_name" and "last_name" both match the regex's specified
    - "email" is a valid EMAIL format
    - "password" passes the checks done by check_password(), meaning
       that the sub returns true
    - "confirm_password" is equal to the "password" field

B<Any regular expressions you specify must be enclosed in single quotes
because they need to be used in both JavaScript and Perl code.> As
such, specifying a C<qr//> will NOT work.

Note that for both the C<javascript> and C<perl> hashref code options,
the form will be present as the variable named C<form>. For the Perl
code, you actually get a complete C<$form> object meaning that you
have full access to all its methods (although the C<field()> method
is probably the only one you'll need for validation).

In addition to taking any regular expression you'd like, the
C<validate> option also has many builtin defaults that can
prove helpful:

    VALUE   -  is any type of non-null value
    WORD    -  is a word (\w+)
    NAME    -  matches [a-zA-Z] only
    FNAME   -  person's first name, like "Jim" or "Joe-Bob"
    LNAME   -  person's last name, like "Smith" or "King, Jr."
    NUM     -  number, decimal or integer
    INT     -  integer
    FLOAT   -  floating-point number
    PHONE   -  phone number in form "123-456-7890" or "(123) 456-7890"
    INTPHONE-  international phone number in form "+prefix local-number"
    EMAIL   -  email addr in form "name@host.domain"
    CARD    -  credit card, including Amex, with or without -'s
    DATE    -  date in format MM/DD/YYYY
    EUDATE  -  date in format DD/MM/YYYY
    MMYY    -  date in format MM/YY or MMYY
    MMYYYY  -  date in format MM/YYYY or MMYYYY
    CCMM    -  strict checking for valid credit card 2-digit month ([0-9]|1[012])
    CCYY    -  valid credit card 2-digit year
    ZIPCODE -  US postal code in format 12345 or 12345-6789
    STATE   -  valid two-letter state in all uppercase
    IPV4    -  valid IPv4 address
    NETMASK -  valid IPv4 netmask
    FILE    -  UNIX format filename (/usr/bin)
    WINFILE -  Windows format filename (C:\windows\system)
    MACFILE -  MacOS format filename (folder:subfolder:subfolder)
    HOST    -  valid hostname (some-name)
    DOMAIN  -  valid domainname (www.i-love-bacon.com)
    ETHER   -  valid ethernet address using either : or . as separators

I know some of the above are US-centric, but then again that's where I live. :-)
So if you need different processing just create your own regular expression
and pass it in. If there's something really useful let me know and maybe
I'll add it.

=back

Note that any other options specified are passed to the C<< <form> >>
tag verbatim. For example, you could specify C<onSubmit> or C<enctype>
to add the respective attributes.

=head2 render()

This function renders the form into HTML, and returns a string
containing the form. The most common use is simply:

    print $form->render;

You can also supply options to C<render()>, just like you had
called the accessor functions individually. These two uses are
equivalent:

    # this code:
    $form->header(1);
    $form->stylesheet('style.css');
    print $form->render;

    # is the same as:
    print $form->render(header => 1,
                        stylesheet => 'style.css');

Note that both forms make permanent changes to the underlying
object. So the next call to C<render()> will still have the 
header and stylesheet options in either case.

=head2 field()

This method is used to both get at field values:

    my $bday = $form->field('birthday');

As well as make changes to their attributes:

    $form->field(name  => 'fname',
                 label => "First Name");

A very common use is to specify a list of options and/or the field type:

    $form->field(name    => 'state',
                 type    => 'select',
                 options => \@states);      # you supply @states

In addition, when you call C<field()> without any arguments, it returns
a list of valid field names in an array context:

    my @fields = $form->field;

And a hashref of field/value pairs in scalar context:

    my $fields = $form->field;
    my $name = $fields->{name};

Note that if you call it in this manner, you only get one single
value per field. This is fine as long as you don't have multiple
values per field (the normal case). However, if you have a field
that allows multiple options:

    $form->field(name => 'color', options => \@colors,
                 multiple => 1);        # allow multi-select

Then you will only get one value for C<color> in the hashref. In
this case you'll need to access it via C<field()> to get them all:

    my @colors = $form->field('color');

Here is a quick list of C<field()> options, organized by use:

    my $value = $form->field(
                    # important options
                    name       => $name,
                    label      => $string,
                    multiple   => 0 | 1,
                    options    => \@options | \%options,
                    type       => $type,
                    value      => $value | \@values,

                    # lesser-used options
                    force      => 0 | 1,
                    jsclick    => $jscode,    # instead of onClick
                    required   => 0 | 1,      # in new() more useful
                    validate   => '/regex/',  # in new() more useful

                    # formatting options
                    columns    => 0 | $width,
                    comment    => $string,
                    labels     => \%hash,     # use data to "options"
                    linebreaks => 0 | 1,
                    nameopts   => 0 | 1,
                    sortopts   => 'NAME' | 'NUM' | 1 | &sub,

                    # change size, maxlength, or any HTML attr
                    $htmlattr  => $htmlval,
                );

The C<name> option is listed first, and then the rest are in order:

=over

=item name => $name

The field to manipulate. The "name =>" part is optional if it's the
only argument. For example:

    my $email = $form->field(name => 'email');
    my $email = $form->field('email');   # same thing

However, if you're specifying more than one argument, then you must
include the C<name> part:

    $form->field(name => 'email', size => '40');

=item columns => 0 | $width

If set and the field is of type 'checkbox' or 'radio', then the
options will be wrapped at the given width.

=item comment => $string

This prints out the given comment I<after> the field. A good use of
this is for additional help on what the field should contain:

    $form->field(name    => 'dob',
                 label   => 'D.O.B.',
                 comment => 'in the format MM/DD/YY');

The above would yield something like this:

    D.O.B. [____________] in the format MM/DD/YY

The comment is rendered verbatim, meaning you can use HTML links
or code in it if you want.

=item force => 0 | 1

This is used in conjunction with the C<value> option to forcibly
override a field's value. See below under the C<value> option for
more details. For compatibility with C<CGI.pm>, you can also call
this option C<override> instead, but don't tell anyone.

=item jsclick => $jscode

This is a cool abstraction over directly specifying the JavaScript
action. This turns out to be extremely useful, since if a field
type changes from C<select> to C<radio> or C<checkbox>, then the
action changes from C<onChange> to C<onClick>. Why?!?!

So if you said:

    $form->field(name    => 'credit_card', 
                 options => \@cards,
                 jsclick => 'recalc_total();');

This would generate the following code, depending on the number
of C<@cards>:

    <select name="credit_card" onChange="recalc_total();"> ...

    <radio name="credit_card" onClick="recalc_total();"> ...

You get the idea.

=item label => $string

This is the label printed out before the field. By default it is 
automatically generated from the field name. If you want to be
really lazy, get in the habit of naming your database fields as
complete words so you can pass them directly to/from your form.

=item labels => \%hash

B<This option to field() is outdated.> You can get the same effect by
passing data structures directly to the C<options> argument (see below).
If you have well-named data, check out the C<nameopts> option.

This takes a hashref of key/value pairs where each key is one of
the options, and each value is what its printed label should be:

    $form->field(name    => 'state',
                 options => [qw(AZ CA NV OR WA)],
                 labels  => {
                      AZ => 'Arizona',
                      CA => 'California',
                      NV => 'Nevada',
                      OR => 'Oregon',
                      WA => 'Washington
                 });

When rendered, this would create a select list where the option
values were "CA", "NV", etc, but where the state's full name
was displayed for the user to select. As mentioned, this has
the exact same effect:

    $form->field(name    => 'state',
                 options => [
                    [ AZ => 'Arizona' ], 
                    [ CA => 'California' ],
                    [ NV => 'Nevada' ],
                    [ OR => 'Oregon' ],
                    [ WA => 'Washington ],
                 ]);

I can think of some rare situations where you might have a set
of predefined labels, but only some of those are present in a
given field... but usually you should just use the C<options> arg.

=item linebreaks => 0 | 1

Similar to the top-level "linebreaks" option, this one will put
breaks in between options, to space things out more. This is
useful with radio and checkboxes especially.

=item multiple => 0 | 1

If set to 1, then the user is allowed to choose multiple
values from the options provided. This turns radio groups
into checkboxes and selects into multi-selects. Defaults
to automatically being figured out based on number of values.

=item nameopts => 0 | 1

If set to 1, then options for select lists will be automatically
named just like the fields. So, if you specified a list like:

    $form->field(name     => 'department', 
                 options  => qw[(molecular_biology
                                 philosophy psychology
                                 particle_physics
                                 social_anthropology)],
                 nameopts => 1);

This would create a list like:

    <select name="department">
    <option value="molecular_biology">Molecular Biology</option>
    <option value="philosophy">Philosophy</option>
    <option value="psychology">Psychology</option>
    <option value="particle_physics">Particle Physics</option>
    <option value="social_anthropology">Social Anthropology</option>
    </select>

Basically, you get names for the options that are determined in 
the same way as the names for the fields. This is designed as
a simpler alternative to using custom C<options> data structures
if your data is regular enough to support it.

=item options => \@options | \%options

This takes an arrayref of options. It also automatically results
in the field becoming a radio (if < 5) or select list (if >= 5),
unless you explicitly set the type with the C<type> parameter:

    $form->field(name => 'opinion',
                 options => [qw(yes no maybe so)]);

From that, you will get something like this:

    <select name="opinion">
    <option value="yes">yes</option>
    <option value="no">no</option>
    <option value="maybe">maybe</option>
    <option value="so">so</option>
    </select>

Also, this can accept more complicated data structures, allowing you to 
specify different labels and values for your options. If a given item
is either an arrayref or hashref, then the first element will be
taken as the value and the second as the label. For example, this:

    push @opt, ['yes', 'You betcha!'];
    push @opt, ['no', 'No way Jose'];
    push @opt, ['maybe', 'Perchance...'];
    push @opt, ['so', 'So'];
    $form->field(name => 'opinion', options => \@opt);

Would result in something like the following:

    <select name="opinion">
    <option value="yes">You betcha!</option>
    <option value="no">No way Jose</option>
    <option value="maybe">Perchance...</option>
    <option value="so">So</option>
    </select>

And this code would have the same effect:

    push @opt, { yes => 'You betcha!' };
    push @opt, { no  => 'No way Jose' };
    push @opt, { maybe => 'Perchance...' };
    push @opt, { so  => 'So' };
    $form->field(name => 'opinion', options => \@opt);

As would, in fact, this code:

    my @opt = (
        [ yes => 'You betcha!' ],
        [ no  => 'No way Jose' ],
        [ maybe => 'Perchance...' ],
        [ so  => 'So' ]
    );
    $form->field(name => 'opinion', options => \%opt);

You get the idea. The goal is to give you as much flexibility
as possible when constructing your data structures, and this
module figures it out correctly.

=item required => 0 | 1

If set to 1, the field must be filled in:

    $form->field(name => 'email', required => 1);

This is rarely useful - what you probably want are the C<validate>
and C<required> options to C<new()>.

=item sortopts => 'NAME' | 'NUM' | 1 | \&sub

If set, and there are options, then the options will be sorted 
in the specified order. For example:

    $form->field(name => 'category', options => \@cats,
                 sortopts => 'NAME');

Would sort the C<@cats> options in alphabetic (C<NAME>) order.
The option C<NUM> would sort them in numeric order. If you 
specify "1", then an alphabetic sort is done, just like the
default Perl sort.

In addition, you can specify a sub reference which takes pairs
of values to compare and returns the appropriate return value
that Perl C<sort()> expects.

=item type => $type

The type of input box to create. Default is "text", and valid values
include anything allowed by the HTML specs, including "select",
"radio", "checkbox", "textarea", "password", "hidden", and so on.

By default, the type is automatically determined by B<FormBuilder>
based on the following algorithm:

    Field options?
        No = text (done)
        Yes:
            Less than 'selectnum' setting?
                No = select (done)
                Yes:
                    Is the 'multiple' option set?
                    Yes = checkbox (done)
                    No:
                        Have just one single option?
                            Yes = checkbox (done)
                            No = radio (done)

I recommend you let B<FormBuilder> do this for you in most cases,
and only tweak those you really need to.

=item value => $value | \@values

The C<value> option can take either a single value or an arrayref
of multiple values. In the case of multiple values, this will
result in the field automatically becoming a multiple select list
or radio group, depending on the number of options specified.

B<If a CGI value is present it will always win.> To forcibly change
a value, you need to specify the C<force> option:

    # Example that hides credit card on confirm screen
    if ($form->submitted && $form->validate) {
        my $val = $form->field;

        # hide CC number
        $form->field(name => 'credit_card',
                     value => '(not shown)',
                     force => 1);

        print $form->confirm;
    }

This would print out the string "(not shown)" on the C<confirm()>
screen instead of the actual number.

=item validate => '/regex/'

Similar to the C<validate> option used in C<new()>, this affects
the validation just of that single field. As such, rather than
a hashref, you would just specify the regex to match against.

B<This regex must be specified as a single-quoted string, and
NOT as a qr// regex>. The reason for this is it needs to be
usable by the JavaScript routines as well.

=item $htmlattr => $htmlval

In addition to the above tags, the C<field()> function can take
any other valid HTML attribute, which will be placed in the tag
verbatim. For example, if you wanted to alter the class of the
field (if you're using stylesheets and a template, for example),
you could say:

    $form->field(name => 'email', class => 'FormField',
                 size => 80);

Then when you call C<$form->render> you would get a field something
like this:

    <input type="text" name="email" class="FormField" size="80">

(Of course, for this to really work you still have to create a class
called C<FormField> in your stylesheet.)

See also the C<fieldattr> option which provides global attributes
to all fields.

=back

=head2 cgi_param()

The above C<field()> function does a bunch of special stuff. 
For one thing, it will only return fields which you have I<explicitly>
defined in your form. Excess parameters will be silently ignored.
Also, it will incorporate defaults you give it, meaning you may
get a value back even though the user didn't enter one in the
form (see above).

But, you may have some times when you want extra params so that
you can maintain state, but you don't want it to appear in your
form. Branding is an easy example:

    http://hr-outsourcing.com/newuser.cgi?company=mr_propane

This could change your page's HTML so that it displayed the
appropriate company name and logo, without polluting your
form parameters.

This call simply redispatches to C<CGI.pm>'s C<param()> method,
so consult those docs for more information.

=head2 confirm()

The purpose of this function is to print out a static confirmation
screen showing a short message along with the values that were
submitted. It is actually just a special wrapper around C<render()>,
twiddling a couple options.

If you're using templates, you probably want to specify a separate
success template, such as:

    if ($form->submitted && $form->validate) {
        print $form->confirm(template => 'success.tmpl');
    } else {
        print $form->render(template => 'fillin.tmpl');
    }

So that you don't get the same screen twice.

=head2 submitted()

This returns the value of the "Submit" button if the form has been
submitted, undef otherwise. This allows you to either test it in
a boolean context:

    if ($form->submitted) { ... }

Or to retrieve the button that was actually clicked on in the
case of multiple submit buttons:

    if ($form->submitted eq 'Update') {
        ...
    } elsif ($form->submitted eq 'Delete') {
        ...
    }

It's best to call C<validate()> in conjunction with this to make
sure the form validation works. To make sure you're getting accurate
info, it's recommended that you name your forms with the C<name>
option described above.

If you're writing a multiple-form app, you should name your forms
with the C<name> option to ensure that you are getting an accurate
return value from this sub. See the C<name> option above, under
C<render()>.

You can also specify the name of an optional field which you want to
"watch" instead of the default C<_submitted> hidden field. This is useful
if you have a search form and also want to be able to link to it from
other documents directly, such as:

    mysearch.cgi?lookup=what+to+look+for

Normally, C<submitted()> would return false since the C<_submitted>
field is not included. However, you can override this by saying:

    $form->submitted('lookup');

Then, if the lookup field is present, you'll get a true value.
(Actually, you'll still get the value of the "Submit" button if
present.)

=head2 validate()

This validates the form based on the validation criteria passed
into C<new()> via the C<validate> option. In addition, you can
specify additional criteria to check that will be valid for just
that call of C<validate()>. This is useful is you have to deal
with different geos:

    if ($location eq 'US') {
        $form->validate(state => 'STATE', zipcode => 'ZIPCODE');
    } else {
        $form->validate(state => '/^\w{2,3}$/');
    }

Note that if you pass args to your C<validate()> function like
this, you will not get JavaScript generated or required fields
placed in bold. So, this is good for conditional validation
like the above example, but for most applications you want to
pass your validation requirements in via the C<validate>
option to the C<new()> function, and just call the C<validate()>
function with no arguments.

=head2 sessionid()

This gets and sets the sessionid, which is stored in the special
form field C<_sessionid>. By default no session ids are generated
or used. Rather, this is intended to provide a hook for you to 
easily integrate this with a session id module like C<Apache::Session>.

Since you can set the session id via the C<_sessionid> field, you
can pass it as an argument when first showing the form:

    http://mydomain.com/forms/update_info.cgi?_sessionid=0123-091231

This would set things up so that if you called:

    my $id = $form->sessionid;

This would get the value C<0123-091231> in your script. Conversely,
if you generate a new sessionid on your own, and wish to include it
automatically, simply set is as follows:

    $form->sessionid($id);

This will cause it to be automatically carried through subsequent
forms.

=head2 mailconfirm()

This sends a confirmation email to the named addresses. The C<to>
argument is required; everything else is optional. If no C<from>
is specified then it will be set to the address C<auto-reply>
since that is a common quasi-standard in the web app world.

This does not send any of the form results. Rather, it simply
prints out a message saying the submission was received.

=head2 mailresults()

This emails the form results to the specified address(es). By 
default it prints out the form results separated by a colon, such as:

    name: Nathan Wiger
    email: nate@wiger.org
    colors: red green blue

And so on. You can change this by specifying the C<delimiter> and
C<joiner> options. For example this:

    $form->mailresults(to => $to, delimiter => '=', joiner => ',');

Would produce an email like this:

    name=Nathan Wiger
    email=nate@wiger.org
    colors=red,green,blue

Note that now the last field ("colors") is separated by commas since
you have multiple values and you specified a comma as your C<joiner>.

=head2 mail()

This is a more generic version of the above; it sends whatever is
given as the C<text> argument via email verbatim to the C<to> address.
In addition, if you're not running C<sendmail> you can specify the
C<mailer> parameter to give the path of your mailer. This option
is accepted by the above functions as well.

=head1 EXAMPLES

I find this module incredibly useful, so here are even more examples,
pasted from sample code that I've written:

=head2 Ex1: order.cgi

This example provides an order form, complete with validation of the
important fields, and a "Cancel" button to abort the whole thing.

    #!/usr/bin/perl -w

    use strict;
    use CGI::FormBuilder;

    my @states = my_state_list();   # you write this

    my $form = CGI::FormBuilder->new(
                    method => 'POST',
                    fields => [
                        qw(first_name last_name
                           email send_me_emails
                           address state zipcode
                           credit_card expiration)
                    ],

                    header => 1,
                    title  => 'Finalize Your Order',
                    submit => ['Place Order', 'Cancel'],
                    reset  => 0,

                    validate => {
                         email   => 'EMAIL',
                         zipcode => 'ZIPCODE',
                         credit_card => 'CARD',
                         expiration  => 'MMYY',
                    },
                    required => 'ALL',
                    jsfunc => <<EOJS,
    // skip js validation if they clicked "Cancel"
    if (this._submit.value == 'Cancel') return true;
EOJS
               );

    # Provide a list of states
    $form->field(name    => 'state',
                 options => \@states,
                 sortopts=> 'NAME');

    # Options for mailing list
    $form->field(name    => 'send_me_emails',
                 options => [[1 => 'Yes'], [0 => 'No']],
                 value   => 0,   # "No"

    # Check for valid order
    if ($form->submitted eq 'Cancel') {
        # redirect them to the homepage
        print $form->cgi->redirect('/');
        exit; 
    }
    elsif ($form->submitted && $form->validate) {
        # your code goes here to do stuff...
        print $form->confirm;
    }
    else {
        # either first printing or needs correction
        print $form->render;
    }

This will create a form called "Finalize Your Order" that will provide a
pulldown menu for the C<state>, a radio group for C<send_me_emails>, and
normal text boxes for the rest. It will then validate all the fields,
using specific patterns for those fields specified to C<validate>.

=head2 Ex2: order_form.cgi

Here's an example that adds some fields dynamically, and uses the
C<debug> option spit out gook:

    #!/usr/bin/perl -w

    use strict;
    use CGI::FormBuilder;

    my $form = CGI::FormBuilder->new(
                    method => 'POST',
                    fields => [
                        qw(first_name last_name email
                           address state zipcode)
                    ],
                    header => 1,
                    debug  => 2,    # gook
                    required => 'NONE',
               );

    # This adds on the 'details' field to our form dynamically
    $form->field(name => 'details',
                 type => 'textarea',
                 cols => '50',
                 rows => '10');

    # And this adds user_name with validation
    $form->field(name  => 'user_name',
                 value => $ENV{REMOTE_USER},
                 validate => 'NAME');

    if ($form->submitted && $form->validate) {
        # ... more code goes here to do stuff ...
        print $form->confirm;
    } else {
        print $form->render;
    }

In this case, none of the fields are required, but the C<user_name>
field will still be validated if filled in.

=head2 Ex3: ticket_search.cgi

This is a simple search script that uses a template to layout 
the search parameters very precisely. Note that we set our
options for our different fields and types.

    #!/usr/bin/perl -w

    use strict;
    use CGI::FormBuilder;

    my $form = CGI::FormBuilder->new(
                    fields => [qw(type string status category)],
                    header => 1,
                    template => 'ticket_search.tmpl',
                    submit => 'Search',     # search button
                    reset  => 0,            # and no reset
               );

    # Need to setup some specific field options
    $form->field(name    => 'type',
                 options => [qw(ticket requestor hostname sysadmin)]);

    $form->field(name    => 'status',
                 type    => 'radio',
                 options => [qw(incomplete recently_completed all)],
                 value   => 'incomplete');

    $form->field(name    => 'category',
                 type    => 'checkbox',
                 options => [qw(server network desktop printer)]);

    # Render the form and print it out so our submit button says "Search"
    print $form->render;

Then, in our C<ticket_search.tmpl> HTML file, we would have something like this:

    <html>
    <head>
      <title>Search Engine</title>
      <tmpl_var js-head>
    </head>
    <body bgcolor="white">
    <center>
    <p>
    Please enter a term to search the ticket database.
    <p>
    <tmpl_var form-start>
    Search by <tmpl_var field-type> for <tmpl_var field-string>
    <tmpl_var form-submit>
    <p>
    Status: <tmpl_var field-status>
    <p>
    Category: <tmpl_var field-category>
    <p>
    </form>
    </body>
    </html>

That's all you need for a sticky search form with the above HTML layout.
Notice that you can change the HTML layout as much as you want without
having to touch your CGI code.

=head2 Ex4: user_info.cgi

This script grabs the user's information out of a database and lets
them update it dynamically. The DBI information is provided as an
example, your mileage may vary:

    #!/usr/bin/perl -w

    use strict;
    use CGI::FormBuilder;
    use DBI;
    use DBD::Oracle

    my $dbh = DBI->connect('dbi:Oracle:db', 'user', 'pass');

    # We create a new form. Note we've specified very little,
    # since we're getting all our values from our database.
    my $form = CGI::FormBuilder->new(
                    fields => [qw(username password confirm_password
                                  first_name last_name email)]
               );

    # Now get the value of the username from our app
    my $user = $form->cgi_param('user');
    my $sth = $dbh->prepare("select * from user_info where user = '$user'");
    $sth->execute;
    my $default_hashref = $sth->fetchrow_hashref;

    # Render our form with the defaults we got in our hashref
    print $form->render(values => $default_hashref,
                        title  => "User information for '$user'",
                        header => 1);

=head2 Ex5: add_part.cgi

This presents a screen for users to add parts to an inventory database.
Notice how it makes use of the C<sticky> option. If there's an error,
then the form is presented with sticky values so that the user can
correct them and resubmit. If the submission is ok, though, then the
form is presented without sticky values so that the user can enter
the next part.

    #!/usr/bin/perl -w

    use strict;
    use CGI::FormBuilder;

    my $form = CGI::FormBuilder->new(
                    method => 'POST',
                    fields => [qw(sn pn model qty comments)],
                    labels => {
                        sn => 'Serial Number',
                        pn => 'Part Number'
                    },
                    sticky => 0,
                    header => 1,
                    required => [qw(sn pn model qty)],
                    validate => {
                         sn  => '/^[PL]\d{2}-\d{4}-\d{4}$/',
                         pn  => '/^[AQM]\d{2}-\d{4}$/',
                         qty => 'INT'
                    },
                    font => 'arial,helvetica'
               );

    # shrink the qty field for prettiness, lengthen model
    $form->field(name => 'qty',   size => 4);
    $form->field(name => 'model', size => 60);

    if ($form->submitted) {
        if ($form->validate) {
            # Add part to database
        } else {
            # Invalid; show form and allow corrections
            print $form->render(sticky => 1);
            exit;
        }
    }

    # Print form for next part addition.
    print $form->render;

With the exception of the database code, that's the whole application.

=head1 FREQUENTLY ASKED QUESTIONS (FAQ)

There are a couple questions and subtle traps that seem to poke people
on a regular basis. Here are some hints.

=head2 I'm confused. Why doesn't this work like CGI.pm?

If you're used to C<CGI.pm>, you have to do a little bit of a brain
shift when working with this module.

B<FormBuilder> is designed to address fields as I<abstract entities>.
That is, you don't create a "checkbox" or "radio group" per se.
Instead, you create a field for the data you want to collect.
The HTML representation is just one property of this field.

So, if you want a single-option checkbox, simply say something
like this:

    $form->field(name    => 'join_mailing_list',
                 options => ['Yes']);

If you want it to be checked by default, you add the C<value> arg:

    $form->field(name    => 'join_mailing_list',
                 options => ['Yes'],
                 value   => 'Yes');

You see, you're creating a field that has one possible option: "Yes".
Then, you're saying its current value is, in fact, "Yes". This will
result in B<FormBuilder> creating a single-option field (which is
a checkbox by default) and selecting the requested value (meaning
that the box will be checked).

If you want multiple values, then all you have to do is specify
multiple options:

    $form->field(name    => 'join_mailing_list',
                 options => ['Yes', 'No'],
                 value   => 'Yes');

Now you'll get a radio group, and "Yes" will be selected for you!
By viewing fields as data entities (instead of HTML tags) you
get much more flexibility and less code maintenance. If you want
to be able to accept multiple values, simply use the C<multiple> arg:

    $form->field(name     => 'favorite_colors',
                 options  => [qw(red green blue)],
                 multiple => 1);

In all of these examples, to get the data back you just use the
C<field()> method:

    my @colors = $form->field('favorite_colors');

And the rest is taken care of for you.

=head2 How do I make a multi-screen/multi-mode form?

This is easily doable, but you have to remember a couple things. Most
importantly, that B<FormBuilder> only knows about those fields you've
told it about. So, let's assume that you're going to use a special
parameter called C<mode> to control the mode of your application so
that you can call it like this:

    myapp.cgi?mode=list&...
    myapp.cgi?mode=edit&...
    myapp.cgi?mode=remove&...

And so on. You need to do two things. First, you need the C<keepextras>
option:

    my $form = CGI::FormBuilder->new(..., keepextras => 1);

This will maintain the C<mode> field as a hidden field across requests
automatically. Second, you need to realize that since the C<mode> is
not a defined field, you have to get it via the C<cgi_param()> method:

    my $mode = $form->cgi_param('mode');

This will allow you to build a large multiscreen application easily,
even integrating it with modules like C<CGI::Application> if you want.

You can also do this by simply defining C<mode> as a field in your
C<fields> declaration. The reason this is discouraged is because
when iterating over your fields you'll get C<mode>, which you likely
don't want (since it's not "real" data).

=head2 Why won't CGI::FormBuilder work with POST requests?

It will, but chances are you're probably doing something like this:

    use CGI qw(:standard);
    use CGI::FormBuilder;

    # Our "mode" parameter determines what we do
    my $mode = param('mode');

    # Change our form based on our mode
    if ($mode eq 'view') {
        my $form = CGI::FormBuilder->new(
                        method => 'POST',
                        fields => [qw(...)],
                   );
    } elsif ($mode eq 'edit') {
        my $form = CGI::FormBuilder->new(
                        method => 'POST',
                        fields => [qw(...)],
                   );
    }

The problem is this: Once you read a C<POST> request, it's gone
forever. In the above code, what you're doing is having C<CGI.pm>
read the C<POST> request (on the first call of C<param()>).

Luckily, there is an easy solution. First, you need to modify
your code to use the OO form of C<CGI.pm>. Then, simply specify
the C<CGI> object you create to the C<params> option of B<FormBuilder>:

    use CGI;
    use CGI::FormBuilder;

    my $cgi = CGI->new;

    # Our "mode" parameter determines what we do
    my $mode = $cgi->param('mode');

    # Change our form based on our mode
    # Note: since it is POST, must specify the 'params' option
    if ($mode eq 'view') {
        my $form = CGI::FormBuilder->new(
                        method => 'POST',
                        fields => [qw(...)],
                        params => $cgi      # get CGI params
                   );
    } elsif ($mode eq 'edit') {
        my $form = CGI::FormBuilder->new(
                        method => 'POST',
                        fields => [qw(...)],
                        params => $cgi      # get CGI params
                   );
    }

Or, since B<FormBuilder> gives you a C<cgi_param()> function, you
could also modify your code so you use B<FormBuilder> exclusively,
as in the previous question.

=head2 How can I change option XXX based on a conditional?

To change an option, simply use its accessor at any time:

    my $form = CGI::FormBuilder->new(
                    method => 'POST',
                    fields => [qw(name email phone)]
               );

    my $mode = $form->cgi_param('mode');

    if ($mode eq 'add') {
        $form->title('Add a new entry');
    } elsif ($mode eq 'edit') {
        $form->title('Edit existing entry');

        # do something to select existing values
        my %values = select_values();

        $form->values(\%values);
    }
    print $form->render;

Using the accessors makes permanent changes to your object, so
be aware that if you want to reset something to its original
value later, you'll have to first save it and then reset it:

    my $style = $form->stylesheet;
    $form->stylesheet(0);       # turn off
    $form->stylesheet($style);  # original setting

You can also specify options to C<render()>, although using the
accessors is the preferred way.

=head2 How do I manually override the value of a field?

You must specify the C<force> option:

    $form->field(name  => 'name_of_field',
                 value => $value,
                 force => 1);

If you don't specify C<force>, then the CGI value will always win.
This is because of the stateless nature of the CGI protocol.

=head2 How do I make it so that the values aren't shown in the form?

Turn off sticky:

    my $form = CGI::FormBuilder->new(... sticky => 0);

By turning off the C<sticky> option, you will still be able to access
the values, but they won't show up in the form.

=head2 I can't get "validate" to accept my regular expressions!

You're probably not specifying them within single quotes. See the
section on C<validate> above.

=head2 Can FormBuilder handle file uploads?

It sure can, and it's really easy too. Just change the C<enctype>
as an option to C<new()>:

    use CGI::FormBuilder;
    my $form = CGI::FormBuilder->new(
                    enctype => 'multipart/form-data',
                    method  => 'POST',
                    fields  => [qw(filename)]
               );

    $form->field(name => 'filename', type => 'file');

And then get to your file the same way as C<CGI.pm>:

    if ($form->submitted) {
        my $file = $form->field('filename');

        # save contents in file, etc ...
        open F, ">$dir/$file" or die $!;
        while (<$file>) {
            print F;
        }
        close F;

        print $form->confirm(header => 1);
    } else {
        print $form->render(header => 1);
    }

In fact, that's a whole file upload program right there.

=head1 NOTES

Parameters beginning with a leading underscore are reserved for
future use by this module. Use at your own peril.

The output of the HTML generated natively may change slightly from
release to release. If you need precise control, use a template.

Every attempt has been made to make this module taint-safe (-T).
However, due to the way tainting works, you may run into the
message "Insecure dependency" or "Insecure $ENV{PATH}". If so,
make sure you are setting you C<$ENV{PATH}> at the top of your
script. This is actually a good habit regardless.

=head1 SUPPORT

For support, please start by visiting the FormBuilder website at:

    www.formbuilder.org

This site has numerous tutorials and other documentation to help you
use FormBuilder to its full potential. If you can't find the answer
there, then join the mailing list by emailing:

    fbusers-subscribe@formbuilder.org

To submit patches, please first join the mailing list and post your
question or issue. That way we can have a discussion about the best
way to address it.

=head1 REFERENCES

This really doesn't belong here, but unfortunately many people are
confused by references in Perl. Don't be - they're not that tricky.
When you take a reference, you're basically turning something into
a scalar value. Sort of. You have to do this if you want to pass
arrays intact into functions in Perl 5.

A reference is taken by preceding the variable with a backslash (\).
In our examples above, you saw something similar to this:

    my @fields = ('name', 'email');   # same as = qw(name email)

    my $form = CGI::FormBuilder->new(fields => \@fields);

Here, C<\@fields> is a reference. Specifically, it's an array
reference, or "arrayref" for short.

Similarly, we can do the same thing with hashes:

    my %validate = (
        name  => 'NAME';
        email => 'EMAIL',
    );

    my $form = CGI::FormBuilder->new( ... validate => \%validate);

Here, C<\%validate> is a hash reference, or "hashref".

Basically, if you don't understand references and are having trouble
wrapping your brain around them, you can try this simple rule: Any time
you're passing an array or hash into a function, you must precede it
with a backslash. Usually that's true for CPAN modules.

Finally, there are two more types of references: anonymous arrayrefs
and anonymous hashrefs. These are created with C<[]> and C<{}>,
respectively. So, for our purposes there is no real difference between
this code:

    my @fields = qw(name email);
    my %validate = (name => 'NAME', email => 'EMAIL');

    my $form = CGI::FormBuilder->new(
                    fields   => \@fields,
                    validate => \%validate
               );

And this code:

    my $form = CGI::FormBuilder->new(
                    fields   => [ qw(name email) ],
                    validate => { name => 'NAME', email => 'EMAIL' }
               );

Except that the latter doesn't require that we first create 
C<@fields> and C<%validate> variables.

=head1 ACKNOWLEDGEMENTS

This module has really taken off, thanks to very useful input, bug
reports, and encouraging feedback from a number of people, including:

    Norton Allen
    Mark Belanger
    Peter Billam
    Brad Bowman
    Jonathan Buhacoff
    Godfrey Carnegie
    Jakob Curdes
    Bob Egert
    Peter Eichman
    Adam Foxson
    Jorge Gonzalez
    Florian Helmberger
    Mark Houliston
    Robert James Kaes
    Dimitry Kharitonov
    Randy Kobes
    William Large
    Kevin Lubic
    Robert Mathews
    Mehryar
    Koos Pol
    Shawn Poulson
    Dan Collis Puro
    Stephan Springl
    Ryan Tate
    John Theus
    Remi Turboult
    Andy Wardley

Thanks!

=head1 SEE ALSO

L<CGI::FormBuilder::Field>, L<CGI::FormBuilder::Template>, 
L<CGI::FormBuilder::Messages>, L<CGI::FormBuilder::Util>,
L<HTML::Template>, L<Text::Template>, Template Toolkit,
L<CGI>, L<CGI::Application>

=head1 REVISION

$Id: FormBuilder.pm,v 1.25 2005/02/10 20:15:52 nwiger Exp $

=head1 AUTHOR

Copyright (c) 2000-2005 Nathan Wiger, Sun Microsystems <nate@sun.com>.
All Rights Reserved.

This module is free software; you may copy this under the terms of
the GNU General Public License, or the Artistic License, copies of
which should have accompanied your Perl kit.

=cut
