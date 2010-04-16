package Text::Xslate::Parser;
use 5.010;
use Mouse;
use Mouse::Util::TypeConstraints;
use warnings FATAL => 'all';

use Text::Xslate::Symbol;

use constant _DUMP_PROTO => !!$ENV{XSLATE_DUMP_PROTO};

my $dquoted = qr/" (?: \\. | [^"\\] )* "/xms;
my $squoted = qr/' (?: \\. | [^'\\] )* '/xms;
my $QUOTED  = qr/(?: $dquoted | $squoted )/xms;

my $NUMBER  = qr/(?: [+-]? [0-9]+ (?: \. [0-9]+)? )/xms;

my $ID = qr/(?: [A-Za-z_][A-Za-z0-9_]* )/xms;

my $OPERATOR = sprintf '(?:%s)', join('|', map{ quotemeta } qw(
    -- ++
    == != <=> <= >=
    << >>
    && ||
    -> =>

    < >
    + - * / %
    & | ^ 
    !
    .
    ? :
    ( )
    { }
    [ ]
    ;
), ',');


my $COMMENT = qr/\# [^\n;]* [;\n]?/xms;

has symbol_table => (
    is  => 'ro',
    isa => 'HashRef',

    default  => sub{ {} },

    init_arg => undef,
);

has scope => (
    is  => 'rw',
    isa => 'ArrayRef[HashRef]',

    default => sub{ [ {} ] },

    required => 0,
);

has token => (
    is  => 'rw',
    isa => 'Object',

    init_arg => undef,
);

has input => (
    is  => 'rw',
    isa => 'Str',

    init_arg => undef,
);


my $token_pattern_t = subtype __PACKAGE__ . '.token_pattern', as 'Regexp';

coerce __PACKAGE__ . '.token_pattern',
    from 'Str', via { qr/\Q$_\E/ms };

has line_start => (
    is      => 'ro',
    isa     => $token_pattern_t,
    coerce  => 1,
    default => sub{ qr/\?/xms },
);

has tag_start => (
    is      => 'ro',
    isa     => $token_pattern_t,
    coerce  => 1,
    default => sub{ qr/\<\?/xms },
);

has tag_end => (
    is      => 'ro',
    isa     => $token_pattern_t,
    coerce  => 1,
    default => sub{ qr/\?\>/xms },
);


sub _trim {
    my($s) = @_;

    $s =~ s/\A \s+         //xms;
    $s =~ s/   [ \t]+ \n?\z//xms;

    return $s;
}

sub split {
    my ($self, $_) = @_;

    my @tokens;

    my $line_start    = $self->line_start;
    my $tag_start     = $self->tag_start;
    my $tag_end       = $self->tag_end;

    my $code_rx = qr/ (?: (?: $QUOTED | [^'"] )*? ) /xms;

    my @state = 'text';

    while($_) {
        if(s/\A ^$line_start ([^\n]* \n?) //xms) {
            push @tokens,
                [ code => _trim($1) ];
        }
        elsif(s/\A ([^\n]*?) $tag_start ($code_rx) $tag_end //xms) {
            if($1){
                push @tokens, [ text => $1 ];
            }
            push @tokens,
                [ code => _trim($2) ];
        }
        elsif(s/\A ([^\n]* \n) //xms) {
            push @tokens, [ text => $1 ];
        }
        else {
            push @tokens, [ text => $_ ];
            last;
        }
    }

    return \@tokens;
}

sub preprocess {
    my $self = shift;

    my $tokens_ref = $self->split(@_);
    my $code = '';

    foreach my $token(@{$tokens_ref}) {
        given($token->[0]) {
            when('text') {
                my $s = $token->[1];
                $s =~ s/(["\\])/\\$1/gxms;

                if($s =~ s/\n/\\n/xms) {
                    $code .= qq{print_raw "$s";\n};
                }
                else {
                    $code .= qq{print_raw "$s";};
                }
            }
            when('code') {
                my $s = $token->[1];
                $s =~ s/\A =/print/xms;

                #if($s =~ /[\{\}\[\]]\n?\z/xms){ # ???
                if($s =~ /[\}\]]\n?\z/xms){
                    $code .= $s;
                }
                elsif(chomp $s) {
                    $code .= qq{$s;\n};
                }
                else {
                    $code .= qq{$s;};
                }
            }
            default {
                confess "Unknown token: $_";
            }
        }
    }
    warn $code, "\n" if _DUMP_PROTO;
    return $code;
}

sub next_token {
    my($self) = @_;

    local *_ = \$self->{input};

    s/\A \s+ //xms;

    if(s/\A ($ID)//xmso){
        return [ name => $1 ];
    }
    elsif(s/\A ($QUOTED)//xmso){
        return [ string => $1 ];
    }
    elsif(s/\A ($NUMBER)//xmso){
        return [ number => $1 ];
    }
    elsif(s/\A (\$ $ID)//xmso) {
        return [ variable => $1 ];
    }
    elsif(s/\A ($OPERATOR)//xmso){
        return [ operator => $1 ];
    }
    elsif(s/\A $COMMENT //xmso) {
        goto &next_token; # tail call
    }
    elsif(s/\A (\S+)//xms) {
        confess("Unexpected symbol '$1'");
    }
    else { # empty
        return undef;
    }
}

sub parse {
    my($parser, $input) = @_;
    
    $parser->input( $parser->preprocess($input) );

    return $parser->statements();
}

# The grammer

sub BUILD {
    my($parser) = @_;

    # separators
    $parser->symbol(':');
    $parser->symbol(';');
    $parser->symbol(',');
    $parser->symbol(')');
    $parser->symbol(']');
    $parser->symbol('}');
    $parser->symbol('->');
    $parser->symbol('else');

    # meta symbols
    $parser->symbol('(end)');
    $parser->symbol('(name)');

    $parser->symbol('(literal)')->set_nud(\&_nud_literal);
    $parser->symbol('(variable)')->set_nud(\&_nud_literal);

    # operators

    $parser->infix('*', 80);
    $parser->infix('/', 80);
    $parser->infix('%', 80);

    $parser->infix('+', 70);
    $parser->infix('-', 70);


    $parser->infix('<',  60);
    $parser->infix('<=', 60);
    $parser->infix('>',  60);
    $parser->infix('>=', 60);

    $parser->infix('==', 50);
    $parser->infix('!=', 50);

    $parser->infix('|',  40);

    $parser->infix('?', 20, \&_led_ternary);

    $parser->infix('.', 100, \&_led_dot);

    $parser->infixr('&&', 35);
    $parser->infixr('||', 30);

    $parser->prefix('!');

    $parser->prefix('(', \&_nud_paren);

    # statements
    $parser->symbol('{')        ->set_std(\&_std_block);
    #$parser->symbol('var')      ->set_std(\&_std_var);
    $parser->symbol('for')      ->set_std(\&_std_for);
    $parser->symbol('if')       ->set_std(\&_std_if);

    $parser->symbol('print')    ->set_std(\&_std_command);
    $parser->symbol('print_raw')->set_std(\&_std_command);

    return;
}


sub symbol {
    my($parser, $id, $bp) = @_;

    my $s = $parser->symbol_table->{$id};
    if(defined $s) {
        if($bp && $bp >= $s->lbp) {
            $s->lbp($bp);
        }
    }
    else {
        $s = Text::Xslate::Symbol->new(id => $id);
        $s->lbp($bp) if $bp;
        $parser->symbol_table->{$id} = $s;
    }

    return $s;
}


sub advance {
    my($parser, $id) = @_;

    if($id && $parser->token->id ne $id) {
        confess("Expected '$id', but " . $parser->token);
    }

    my $symtab = $parser->symbol_table;

    my $t = $parser->next_token();

    if(not defined $t) {
        $parser->token( $symtab->{"(end)"} );
        return;
    }

    my($arity, $value) = @{$t};
    my $proto;

    given($arity) {
        when("name") {
            $proto = $parser->find($value);
        }
        when("variable") {
            $proto = $parser->find($value);

            if($proto->id eq '(name)') { # undefined variable
                $proto = $symtab->{'(variable)'};
            }
        }
        when("operator") {
            $proto = $symtab->{$value};
            if(!$proto) {
                confess("Unknown operator '$value'");
            }
        }
        when("string") {
            $proto = $symtab->{"(literal)"};
            $arity = "literal";
        }
        when("number") {
            $proto = $symtab->{"(literal)"};
            $arity = "literal";
        }
    }

    if(!$proto) {
        confess "Unexpected token: $value ($arity)";
    }

    return $parser->token( $proto->clone( id => $value, arity => $arity ) );
}

sub expression {
    my($parser, $rbp) = @_;

    my $t = $parser->token;

    $parser->advance();

    my $left = $t->nud($parser);

    while($rbp < $parser->token->lbp) {
        $t = $parser->token;
        $parser->advance();
        $left = $t->led($parser, $left);
    }

    return $left;
}

sub _led_infix {
    my($parser, $symbol, $left) = @_;
    my $bin = $symbol->clone(arity => 'binary');

    $bin->first($left);
    $bin->second($parser->expression($bin->lbp));
    return $bin;
}

sub infix {
    my($parser, $id, $bp, $led) = @_;

    return $parser->symbol($id, $bp)->set_led($led || \&_led_infix);
}

sub _led_infixr {
    my($parser, $symbol, $left) = @_;
    my $bin = $symbol->clone(arity => 'binary');
    $bin->first($left);
    $bin->second($parser->expression($bin->lbp - 1));
    return $bin;
}

sub infixr {
    my($parser, $id, $bp, $led) = @_;

    return $parser->symbol($id, $bp)->set_led($led || \&_led_infixr);
}

sub _led_ternary {
    my($parser, $symbol, $left) = @_;

    my $cond = $symbol->clone(arity => 'ternary');

    $cond->first($left);
    $cond->second($parser->expression(0));
    $parser->advance(":");
    $cond->third($parser->expression(0));
    return $cond;
}

sub _led_dot {
    my($parser, $symbol, $left) = @_;

    my $t = $parser->token;
    if($t->arity ne 'name') {
        confess("Expected a property name");
    }

    my $dot = $symbol->clone(arity => 'binary');

    $dot->first($left);
    $dot->second($t->clone(arity => 'literal'));

    $parser->advance();
    return $dot;
}

sub _nud_prefix {
    my($parser, $symbol) = @_;
    my $un = $symbol->clone(arity => 'unary');
    $parser->reserve($un);
    $un->first($parser->expression(90));
    return $un;
}

sub prefix {
    my($parser, $id, $nud) = @_;

    return $parser->symbol($id)->set_nud($nud || \&_nud_prefix);
}

sub new_scope {
    my($parser) = @_;
    push @{ $parser->scope }, {};
    return;
}

sub find { # find a name from all the scopes
    my($parser, $name) = @_;

    foreach my $scope(reverse @{$parser->scope}){
        my $o = $scope->{$name};
        if($o) {
            return $o;
        }
    }

    my $symtab = $parser->symbol_table;
    return $symtab->{$name} || $symtab->{'(name)'};
}

sub reserve { # reserve a name to the scope
    my($parser, $symbol) = @_;
    if($symbol->arity ne 'name' or $symbol->reserved) {
        return;
    }

    my $top = $parser->scope->[-1];
    my $t = $top->{$symbol->value};
    if($t) {
        if($t->reserved) {
            return;
        }
        if($t->arity eq "name") {
           confess("Already defined: $symbol");
        }
    }
    $top->{$symbol->value} = $symbol;
    $symbol->reserved(1);
    return;
}

sub define { # define a name to the scope
    my($parser, $symbol) = @_;
    my $depth = scalar(@{$parser->scope}) - 1;
    my $top = $parser->scope->[$depth];

    my $t = $top->{$symbol->value};
    if(defined $t) {
        confess($t->reserved ? "Already reserved: $t" : "Already defined: $t");
    }

    $top->{$symbol->value} = $symbol;

    $symbol->reserved(0);
    $symbol->set_nud(\&_nud_literal);
    $symbol->remove_led();
    $symbol->remove_std();
    $symbol->lbp(0);
    $symbol->scope($top);
    $symbol->scope_depth($depth);
    return $symbol;
}

sub pop_scope {
    my($parser) = @_;
    pop @{ $parser->scope };
    return;
}

sub statement { # process one or more statements
    my($parser) = @_;
    my $t = $parser->token;

    if($t->id eq ";"){
        $parser->advance(";");
        return;
    }

    if($t->has_std) { # is $t a statement?
        $parser->advance();
        $parser->reserve($t);
        return $t->std($parser);
    }

    my $expr = $parser->expression(0);
#    if($expr->assignment && $expr->id ne "(") {
#        confess("Bad expression statement");
#    }
    $parser->advance(";");
    return $expr;
}

sub statements { # process statements
    my($parser) = @_;
    my @a;

    $parser->advance();
    while(1) {
        my $t = $parser->token;
        if($t->id eq "}" || $t->id eq "(end)") {
            last;
        }

        push @a, $parser->statement();
    }

    return \@a;
    #return @a == 1 ? $a[0] : \@a;
}

sub block {
    my($parser) = @_;
    my $t = $parser->token;
    $parser->advance("{");
    return $t->std($parser);
}


sub _nud_literal {
    my($parser, $symbol) = @_;
    return $symbol->clone();
}

sub _nud_paren {
    my($parser, $symbol) = @_;
    my $expr = $parser->expression(0);
    $parser->advance(')');
    return $expr;
}

sub _std_block {
    my($parser, $symbol) = @_;
    $parser->new_scope();
    my $a = $parser->statements();
    $parser->advance('}');
    $parser->pop_scope();
    return $a;
}

#sub _std_var {
#    my($parser, $symbol) = @_;
#    my @a;
#    while(1) {
#        my $name = $parser->token;
#        if($name->arity ne "variable") {
#            confess("Expected a new variable name, but $name is not");
#        }
#        $parser->define($name);
#        $parser->advance();
#
#        if($parser->token->id eq "=") {
#            my $t = $parser->token;
#            $parser->advance("=");
#            $t->first($name);
#            $t->second($parser->expression(0));
#            $t->arity("binary");
#            push @a, $t;
#        }
#
#        if($parser->token->id ne ",") {
#            last;
#        }
#        $parser->advance(",");
#    }
#
#    $parser->advance(";");
#    return @a;
#}

sub _std_for {
    my($parser, $symbol) = @_;

    my $for = $symbol->clone(arity => "for");

    $for->first( $parser->expression(0) );

    $parser->advance("->");
    $parser->advance("(");

    my $t = $parser->token;
    if($t->arity ne "variable") {
        confess("Expected a variable name, but $t is not");
    }

    my $iter_var = $t;
    $for->second( $iter_var );

    $parser->advance();

    $parser->advance(")");

    $parser->advance("{");

    $parser->new_scope();
    $parser->define($iter_var);

    $for->third($parser->statements());

    $parser->pop_scope();

    $parser->advance("}");

    return $for;
}

sub _std_if {
    my($parser, $symbol) = @_;

    my $if = $symbol->clone(arity => "if");

    $if->first( $parser->expression(0) );
    $if->second( $parser->block() );

    if($parser->token->id eq "else") {
        $parser->reserve($parser->token);
        $parser->advance("else");
        $if->third( $parser->token->id eq "if"
            ? $parser->statement()
            : $parser->block ());
    }
    return $if;
}

sub _std_command {
    my($parser, $symbol) = @_;
    my @args;
    while(1) {
        push @args, $parser->expression(0);

        if($parser->token->id ne ",") {
            last;
        }
        $parser->advance(",");
    }
    $parser->advance(";");
    return $symbol->clone(args => \@args, arity => 'command');
}

no Mouse::Util::TypeConstraints;
no Mouse;
__PACKAGE__->meta->make_immutable;
