package Text::Xslate::PP::Booster;

use Any::Moose;
use Data::Dumper;
use Carp ();
use Scalar::Util ();

use Text::Xslate::PP::Const;

our $VERSION = '0.1019';

my %CODE_MANIP = ();


has indent_depth => ( is => 'rw', default => 1 );

has indent_space => ( is => 'rw', default => '    ' );

has lines => ( is => 'rw', default => sub { []; } );

has macro_lines => ( is => 'rw', default => sub { []; } );

has ops => ( is => 'rw', default => sub { []; } );

has current_line => ( is => 'rw', default => 0 );

has exprs => ( is => 'rw' );

has sa => ( is => 'rw' );

has sb => ( is => 'rw' );

has lvar => ( is => 'rw', default => sub { []; } ); # local variable

has framename => ( is => 'rw', default => 'main' ); # current frame name

has SP => ( is => 'rw', default => sub { []; } ); # stack

has strict => ( is => 'rw' );

has is_completed => ( is => 'rw', default => 1 );

has stash => ( is => 'rw', default => sub { {}; } ); # store misc data

#
# public APIs
#

sub opcode_to_perlcode {
    my ( $self, $opcode ) = @_;

    my $perlcode = $self->opcode_to_perlcode_string( $opcode );

    # TEST
    print "$perlcode\n" if $ENV{ BOOST_DISP };

    my $evaled_code = eval $perlcode;

    die $@ unless $evaled_code;

    return $evaled_code;
}


sub opcode_to_perlcode_string {
    my ( $self, $opcode, $opt ) = @_;

    #my $tx = Text::Xslate->new;
    #print $tx->_compiler->as_assembly( $opcode );

    $self->_convert_opcode( $opcode, undef, $opt );

    # 書き出し

    my $perlcode =<<'CODE';
sub { no warnings 'recursion';
    my ( $st ) = $_[0];
    my ( $sv, $st2, $pad, %macro, $depth );
    my $output = '';
    my $vars   = $st->{ vars };

    $pad = [ [ ] ];

CODE

    if ( @{ $self->macro_lines } ) {
        $perlcode .= "    # macro\n\n";
        $perlcode .= join ( '', grep { defined } @{ $self->macro_lines } );
    }

    $perlcode .= "\n    # process start\n\n";
    $perlcode .= join( '', grep { defined } @{ $self->{lines} } );
    $perlcode .= "\n" . '    $st->{ output } = $output;' . "\n}";

    return $perlcode;
}


#
# op to perl
#

$CODE_MANIP{ 'noop' } = sub {};


$CODE_MANIP{ 'move_to_sb' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sb( $self->sa );
};


$CODE_MANIP{ 'move_from_sb' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( $self->sb );
};


$CODE_MANIP{ 'save_to_lvar' } = sub {
    my ( $self, $arg, $line ) = @_;
    my $v = sprintf( '( $pad->[ -1 ]->[ %s ] = %s )', $arg, $self->sa );
    $self->lvar->[ $arg ] = $self->sa;
    $self->sa( $v );

    my $op = $self->ops->[ $self->current_line + 1 ];

    unless ( $op and $op->[0] =~ /^(?:print|and|or|dand|dor|push)/ ) { # ...
        $self->write_lines( sprintf( '%s;', $v )  );
    }

};


$CODE_MANIP{ 'local_s' } = sub {
    my ( $self, $arg, $line ) = @_;
    my $key    = $arg;
    my $newval = $self->sa;

    $self->write_lines( sprintf( 'local_s( $st, "%s", %s );', $key, $newval ) );
    $self->write_code( "\n" );
};


$CODE_MANIP{ 'load_lvar_to_sb' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sb( $self->lvar->[ $arg ] );
};


$CODE_MANIP{ 'push' } = sub {
    my ( $self, $arg, $line ) = @_;
    push @{ $self->SP->[ -1 ] }, $self->sa;
};


$CODE_MANIP{ 'pushmark' } = sub {
    my ( $self, $arg, $line ) = @_;
    push @{ $self->SP }, [];
};


$CODE_MANIP{ 'nil' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( 'undef' );
};


$CODE_MANIP{ 'literal' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( '"' . _escape( $arg ) . '"' );
};


$CODE_MANIP{ 'literal_i' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( $arg );
    $self->optimize_to_print( 'num' );
};


$CODE_MANIP{ 'fetch_s' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( sprintf( '$vars->{ "%s" }', _escape( $arg ) ) );
};


$CODE_MANIP{ 'fetch_lvar' } = sub {
    my ( $self, $arg, $line ) = @_;

    $self->sa( sprintf( '$pad->[ -1 ]->[ %s ]', $arg ) );

    return unless $self->is_strict;

    if ( $self->stash->{ in_macro } ) {
        my $macro = $self->stash->{ in_macro };
        unless ( exists $self->stash->{ macro_args_num }->{ $macro }->{ $arg } ) {
            $self->write_lines(
                sprintf(
                    'error_in_booster( $st, %s, %s, "Too few arguments for %s" );',
                    $self->frame_and_line, $self->stash->{ in_macro }
                )
            );
        }
    }

};


$CODE_MANIP{ 'fetch_field' } = sub {
    my ( $self, $arg, $line ) = @_;

    if ( $self->is_strict ) {
        $self->sa( sprintf( 'fetch( $st, %s, %s, %s, %s )', $self->sb(), $self->sa(), $self->frame_and_line ) );
    }
    else {
        $self->sa( sprintf( 'fetch( $st, %s, %s )', $self->sb(), $self->sa() ) );
    }

};


$CODE_MANIP{ 'fetch_field_s' } = sub {
    my ( $self, $arg, $line ) = @_;
    my $sv = $self->sa();

    if ( $self->is_strict ) {
        $self->sa( sprintf( 'fetch( $st, %s, "%s", %s, %s )', $sv, _escape( $arg ), $self->frame_and_line ) );
    }
    else {
        $self->sa( sprintf( 'fetch( $st, %s, "%s" )', $sv, _escape( $arg ) ) );
    }
};


$CODE_MANIP{ 'print_raw' } = sub {
    my ( $self, $arg, $line ) = @_;
    my $sv = $self->sa();
    $self->write_lines( sprintf('$output .= %s;', $sv) );
    $self->write_code( "\n" );
};


$CODE_MANIP{ 'print_raw_s' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->write_lines( sprintf('$output .= "%s";', _escape( $arg ) ) );
    $self->write_code( "\n" );
};


$CODE_MANIP{ 'print' } = sub {
    my ( $self, $arg, $line ) = @_;
    my $sv = $self->sa();
    my $err;

    if ( $self->is_strict ) {
        $err = sprintf( 'warn_in_booster( $st, %s, %s, "Use of nil to be printed" );', $self->frame_and_line );
    }
    else {
        $err = sprintf( 'warn_in_booster( $st, undef, undef, "Use of nil to be printed" );' );
    }


    $self->write_lines( sprintf( <<'CODE', $sv, $err ) );
$sv = %s;

if ( Scalar::Util::blessed( $sv ) and $sv->isa('Text::Xslate::EscapedString') ) {
    $output .= $sv;
}
elsif ( defined $sv ) {
    if ( $sv =~ /[&<>"']/ ) {
        $sv =~ s/&/&amp;/g;
        $sv =~ s/</&lt;/g;
        $sv =~ s/>/&gt;/g;
        $sv =~ s/"/&quot;/g;
        $sv =~ s/'/&apos;/g;
    }
    $output .= $sv;
}
else {
    %s
}
CODE

    $self->write_code( "\n" );
};


$CODE_MANIP{ 'include' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->write_lines( sprintf( <<'CODE', $self->sa ) );
$st2 = Text::Xslate::PP::tx_load_template( $st->self, %s );
{
    local $st2->{local_stack};
    Text::Xslate::PP::tx_execute( $st2, undef, $vars );
    $output .= $st2->{ output };
}

CODE

};


$CODE_MANIP{ 'for_start' } = sub {
    my ( $self, $arg, $line ) = @_;

    $self->stash->{ for_start_line } = $self->current_line;

    push @{ $self->stash->{ for_level } }, {
        stack_id => $arg,
        ar       => $self->sa,
    };
};


$CODE_MANIP{ 'for_iter' } = sub {
    my ( $self, $arg, $line ) = @_;

    $self->stash->{ loop }->{ $self->current_line } = 1; # marked

    my $stack_id = $self->stash->{ for_level }->[ -1 ]->{ stack_id };
    my $ar       = $self->stash->{ for_level }->[ -1 ]->{ ar };

    if ( $self->stash->{ in_macro } ) { # check for fetch_lvar
        $self->stash->{ macro_args_num }->{ $self->framename }->{ $self->sa() } = 1;
    }

    if ( $self->is_strict ) {
        my ( $frame, $line ) = ( "'" . $self->framename . "'", $self->stash->{ for_start_line } );
        $self->write_lines(
            sprintf( 'for ( @{ check_itr_ar( $st, %s, %s, %s ) } ) {', $ar, $frame, $line )
        );
    }
    else {
        $self->write_lines( sprintf( 'for ( @{ %s } ) {', $ar eq 'undef' ? '[]' : $ar ) );
    }

    $self->write_code( "\n" );

    $self->indent_depth( $self->indent_depth + 1 );

    $self->write_lines( sprintf( '$pad->[ -1 ]->[ %s ] = $_;', $self->sa() ) );
    $self->write_code( "\n" );
};


$CODE_MANIP{ 'add' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( sprintf( '( %s + %s )', $self->sb(), $self->sa() ) );
    $self->optimize_to_print( 'num' );
};


$CODE_MANIP{ 'sub' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( sprintf( '( %s - %s )', $self->sb(), $self->sa() ) );
    $self->optimize_to_print( 'num' );
};


$CODE_MANIP{ 'mul' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( sprintf( '( %s * %s )', $self->sb(), $self->sa() ) );
    $self->optimize_to_print( 'num' );
};


$CODE_MANIP{ 'div' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( sprintf( '( %s / %s )', $self->sb(), $self->sa() ) );
    $self->optimize_to_print( 'num' );
};


$CODE_MANIP{ 'mod' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( sprintf( '( %s %% %s )', $self->sb(), $self->sa() ) );
    $self->optimize_to_print( 'num' );
};


$CODE_MANIP{ 'concat' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( sprintf( '( %s . %s )', $self->sb(), $self->sa() ) );
};


$CODE_MANIP{ 'filt' } = sub {
    my ( $self, $arg, $line ) = @_;
    my $i = $self->{ i };
    my $ops = $self->{ ops };

    $self->sa( sprintf('( eval { %s->( %s ) } )', $self->sa, $self->sb ) );
};


$CODE_MANIP{ 'and' } = sub {
    my ( $self, $arg, $line ) = @_;
    return $self->_check_logic( $self->current_line, $arg, 'and' );
};


$CODE_MANIP{ 'dand' } = sub {
    my ( $self, $arg, $line ) = @_;
    return $self->_check_logic( $self->current_line, $arg, 'dand' );
};


$CODE_MANIP{ 'or' } = sub {
    my ( $self, $arg, $line ) = @_;
    return $self->_check_logic( $self->current_line, $arg, 'or' );
};


$CODE_MANIP{ 'dor' } = sub {
    my ( $self, $arg, $line ) = @_;
    return $self->_check_logic( $self->current_line, $arg, 'dor' );
};


$CODE_MANIP{ 'not' } = sub {
    my ( $self, $arg, $line ) = @_;
    my $sv = $self->sa();
    $self->sa( sprintf( '( !%s )', $sv ) );
};


$CODE_MANIP{ 'plus' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( sprintf( '+ %s', $self->sa ) );
};


$CODE_MANIP{ 'minus' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( sprintf( '- %s', $self->sa ) );
};


$CODE_MANIP{ 'eq' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( sprintf( 'cond_eq( %s, %s )', $self->sb(), $self->sa() ) );
};


$CODE_MANIP{ 'ne' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( sprintf( 'cond_ne( %s, %s )', $self->sb(), $self->sa() ) );
};



$CODE_MANIP{ 'lt' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( sprintf( '( %s < %s )', $self->sb(), $self->sa() ) );
};


$CODE_MANIP{ 'le' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( sprintf( '( %s <= %s )', $self->sb(), $self->sa() ) );
};


$CODE_MANIP{ 'gt' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( sprintf( '( %s > %s )', $self->sb(), $self->sa() ) );
};


$CODE_MANIP{ 'ge' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( sprintf( '( %s >= %s )', $self->sb(), $self->sa() ) );
};


$CODE_MANIP{ 'macrocall' } = sub {
    my ( $self, $arg, $line ) = @_;
    my $ops  = $self->ops;

    $self->optimize_to_print( 'num' );

    # mark argument value
    for my $i ( 0 .. $#{ $self->SP->[ -1 ] } ) {
        $self->stash->{ macro_args_num }->{ $self->sa }->{ $i } = 1;
    }

    $self->sa( sprintf( '$macro{\'%s\'}->( $st, %s )',
        $self->sa(),
        sprintf( 'push_pad( $pad, [ %s ] )', join( ', ', @{ pop @{ $self->SP } } )  )
    ) );
};


$CODE_MANIP{ 'macro_begin' } = sub {
    my ( $self, $arg, $line ) = @_;

    $self->stash->{ macro_begin } = $self->current_line;
    $self->stash->{ in_macro } = $arg;
    $self->framename( $arg );

    $self->write_lines( sprintf( '$macro{\'%s\'} = $st->{ booster_macro }->{\'%s\'} ||= sub {', $arg, $arg ) );
    $self->indent_depth( $self->indent_depth + 1 );

    $self->write_lines( 'my ( $st, $pad ) = @_;' );
    $self->write_lines( 'my $vars = $st->{ vars };' );
    $self->write_lines( sprintf( 'my $output = \'\';' ) );
    $self->write_code( "\n" );

    $self->write_lines(
        sprintf( q{Carp::croak('Macro call is too deep (> 100) at "%s"') if ++$depth > 100;}, $arg )
    );
    $self->write_code( "\n" );
};


$CODE_MANIP{ 'macro_end' } = sub {
    my ( $self, $arg, $line ) = @_;

    $self->write_lines( sprintf( '$depth--;' ) );
    $self->write_lines( sprintf( 'pop( @$pad );' ) );
    $self->write_code( "\n" );
    $self->write_lines( sprintf( '$output;' ) );

    $self->indent_depth( $self->indent_depth - 1 );

    $self->write_lines( sprintf( "};\n" ) );
    $self->write_code( "\n" );

    delete $self->stash->{ in_macro };

    push @{ $self->macro_lines },
        splice( @{ $self->{ lines } },  $self->stash->{ macro_begin }, $self->current_line );
};


$CODE_MANIP{ 'macro' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa( $arg );
};


$CODE_MANIP{ 'function' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->sa(
        sprintf('$st->function->{ %s }', $arg )
    );
};


$CODE_MANIP{ 'funcall' } = sub {
    my ( $self, $arg, $line ) = @_;
    my $args_str = join( ', ', @{ pop @{ $self->SP } } );

    $args_str = ', ' . $args_str if length $args_str;

    if ( $self->is_strict ) {
        $self->sa(
            sprintf('call( $st, %s, %s, 0, %s%s )',
                $self->frame_and_line, $self->sa, $args_str
            )
        );
    }
    else {
        $self->sa(
            sprintf('call( $st, undef, undef, 0, %s%s )', $self->sa, $args_str )
        );
    }

};


$CODE_MANIP{ 'methodcall_s' } = sub {
    my ( $self, $arg, $line ) = @_;

    if ( $self->is_strict ) {
        $self->sa(
            sprintf('methodcall( $st, %s, %s, "%s", %s )', $self->frame_and_line, $arg, join( ', ', @{ pop @{ $self->SP } } ) )
        );
    }
    else {
        $self->sa(
            sprintf('methodcall( $st, undef, undef, "%s", %s )', $arg, join( ', ', @{ pop @{ $self->SP } } ) )
        );
    }

};


$CODE_MANIP{ 'goto' } = sub {
    my ( $self, $arg, $line ) = @_;
    my $i = $self->current_line;

    if ( delete $self->stash->{ loop }->{ $i + $arg + 1 } ) { # forブロックを閉じる
        $self->indent_depth( $self->indent_depth - 1 );
        pop @{ $self->stash->{ for_level } };
        $self->write_lines( '}' );
    }
    else {
        die "invalid goto op";
    }

    $self->write_code( "\n" );
};


$CODE_MANIP{ 'depend' } = sub {};


$CODE_MANIP{ 'end' } = sub {
    my ( $self, $arg, $line ) = @_;
    $self->write_lines( "# process end" );
};


#
# Internal APIs
#

sub _spawn_child {
    my ( $self, $opts ) = @_;
    $opts ||= {};
    ( ref $self )->new( { %$opts, strict => $self->strict } ); # inherit strict
}


sub _convert_opcode {
    my ( $self, $ops_orig ) = @_;

    my $ops  = [ map { [ @$_ ] } @$ops_orig ]; # this method is destructive to $ops. so need to copy.
    my $len  = scalar( @$ops );

    # reset
    if ( $self->is_completed ) {
        $self->sa( undef );
        $self->sb( undef );
        $self->lvar( [] );
        $self->lines( [] );
        $self->SP( [] );
        $self->stash( {} );
        $self->is_completed( 0 );
    }

    $self->ops( $ops );

    # create code
    my $i = 0;

    while ( $self->current_line < $len ) {
        my $pair = $ops->[ $i ];

        unless ( $pair and ref $pair eq 'ARRAY' ) {
            Carp::croak( sprintf( "Oops: Broken code found on [%d]",  $i ) );
        }

        my ( $opname, $arg, $line ) = @$pair;

        unless ( $CODE_MANIP{ $opname } ) {
            Carp::croak( sprintf( "Oops: opcode '%s' is not yet implemented on Booster", $opname ) );
        }

        my $manip  = $CODE_MANIP{ $opname };

        if ( my $proc = $self->stash->{ proc }->{ $i } ) {

            if ( $proc->{ skip } ) {
                $self->current_line( ++$i );
                next;
            }

        }

        $manip->( $self, $arg, defined $line ? $line : '' );

        $self->current_line( ++$i );
    }

    $self->is_completed( 1 );

    return $self;
}


sub _check_logic {
    my ( $self, $i, $arg, $type ) = @_;
    my $ops = $self->ops;
    my $type_store = $type;

    my $next_opname = $ops->[ $i + $arg ]->[ 0 ] || '';

    if ( $next_opname =~ /and|or/ ) { # &&, ||
        $type = $type eq 'and'  ? ' && '
              : $type eq 'dand' ? 'defined( %s )'
              : $type eq 'or'   ? ' || '
              : $type eq 'dor'  ? '!(defined( %s ))'
              : die
              ;
        my $pre_exprs = $self->exprs || '';
        $self->exprs( $pre_exprs . $self->sa() . $type ); # store
        return;
    }

    my $opname = $ops->[ $i + $arg - 1 ]->[ 0 ]; # goto or ?
    my $oparg  = $ops->[ $i + $arg - 1 ]->[ 1 ];

    $type = $type eq 'and'  ? '%s'
          : $type eq 'dand' ? 'defined( %s )'
          : $type eq 'or'   ? '!( %s )'
          : $type eq 'dor'  ? '!(defined( %s ))'
          : die
          ;

    if ( $opname eq 'goto' and $oparg > 0 ) { # if-else or ternary?
        my $if_block_start   = $i + 1;                  # open if block
        my $if_block_end     = $i + $arg - 2;           # close if block - subtract goto line
        my $else_block_start = $i + $arg;               # open else block
        my $else_block_end   = $i + $arg + $oparg - 2;  # close else block - subtract goto line

        my ( $sa_1st, $sa_2nd );

        $self->stash->{ proc }->{ $i + $arg - 1 }->{ skip } = 1; # skip goto

        for ( $if_block_start .. $if_block_end ) {
            $self->stash->{ proc }->{ $_ }->{ skip } = 1; # mark skip
        }

        my $st_1st = $self->_spawn_child->_convert_opcode(
            [ @{ $ops }[ $if_block_start .. $if_block_end ] ]
        );

        my $code = $st_1st->code;
        if ( $code and $code !~ /^\n+$/ ) {
            my $expr = $self->sa;
            $expr = ( $self->exprs || '' ) . $expr; # adding expr if exists
            $self->write_lines( sprintf( 'if ( %s ) {' , sprintf( $type, $expr ) ) );
            $self->exprs( '' );
            $self->write_lines( $code );
            $self->write_lines( sprintf( '}' ) );
        }
        else { # treat as ternary
            $sa_1st = $st_1st->sa;
        }

        if ( $else_block_end >= $else_block_start ) {

            for (  $else_block_start .. $else_block_end ) { # 2
                $self->stash->{ proc }->{ $_ }->{ skip } = 1; # skip
            }

            my $st_2nd = $self->_spawn_child->_convert_opcode(
                [ @{ $ops }[ $else_block_start .. $else_block_end ] ]
            );

            my $code = $st_2nd->code;

            if ( $code and $code !~ /^\n+$/ ) {
                $self->write_lines( sprintf( 'else {' ) );
                $self->write_lines( $code );
                $self->write_lines( sprintf( '}' ) );
            }
            else { # treat as ternary
                $sa_2nd = $st_2nd->sa;
            }

        }

        if ( defined $sa_1st and defined $sa_2nd ) {
            my $expr = $self->sa;
            $expr = ( $self->exprs || '' ) . $expr; # adding expr if exists
            $self->sa( sprintf( '(%s ? %s : %s)', sprintf( $type, $expr ), $sa_1st, $sa_2nd ) );
        }
        else {
            $self->write_code( "\n" );
        }

    }
    elsif ( $opname eq 'goto' and $oparg < 0 ) { # while
        my $while_block_start   = $i + 1;                  # open while block
        my $while_block_end     = $i + $arg - 2;           # close while block - subtract goto line

        for ( $while_block_start .. $while_block_end ) {
            $self->stash->{ proc }->{ $_ }->{ skip } = 1; # skip
        }

        $self->stash->{ proc }->{ $i + $arg - 1 }->{ skip } = 1; # skip goto

        my $st_wh = $self->_spawn_child->_convert_opcode(
            [ @{ $ops }[ $while_block_start .. $while_block_end ] ]
        );

        my $expr = $self->sa;
        $expr = ( $self->exprs || '' ) . $expr; # adding expr if exists
        $self->write_lines( sprintf( 'while ( %s ) {' , sprintf( $type, $expr ) ) );
        $self->exprs( '' );
        $self->write_lines( $st_wh->code );
        $self->write_lines( sprintf( '}' ) );

        $self->write_code( "\n" );
    }
    elsif ( _logic_is_max_min( $ops, $i, $arg ) ) { # min, max

        for ( $i + 1 .. $i + 2 ) {
            $self->stash->{ proc }->{ $_ }->{ skip } = 1; # skip
        }

        $self->sa( sprintf( '%s ? %s : %s', $self->sa, $self->sb, $self->lvar->[ $ops->[ $i + 1 ]->[ 1 ] ] ) );
    }
    else { # 

        my $true_start = $i + 1;
        my $true_end   = $i + $arg - 1; # add 1 for complete process line is next.

        for ( $true_start .. $true_end ) {
            $self->stash->{ proc }->{ $_ }->{ skip } = 1; # skip
        }

        my $opts = { sa => $self->sa, sb => $self->sb, lvar => $self->lvar };
        my $st_true  = $self->_spawn_child( $opts )->_convert_opcode(
            [ @{ $ops }[ $true_start .. $true_end ] ]
        );

        my $expr = $self->sa;
        $expr = ( $self->exprs || '' ) . $expr; # adding expr if exists

            $type = $type_store eq 'and'  ? 'cond_and'
                  : $type_store eq 'or'   ? 'cond_or'
                  : $type_store eq 'dand' ? 'cond_dand'
                  : $type_store eq 'dor'  ? 'cond_dor'
                  : die
                  ;

$self->sa( sprintf( <<'CODE', $type, $expr, $st_true->sa ) );
%s( %s, sub {
%s
}, )
CODE

    }

}


sub _logic_is_max_min {
    my ( $ops, $i, $arg ) = @_;
        $ops->[ $i     ]->[ 0 ] eq 'or'
    and $ops->[ $i + 1 ]->[ 0 ] eq 'load_lvar_to_sb'
    and $ops->[ $i + 2 ]->[ 0 ] eq 'move_from_sb'
    and $arg == 2
}


sub _escape {
    my $str = $_[0];
    $str =~ s{\\}{\\\\}g;
    $str =~ s{\n}{\\n}g;
    $str =~ s{\t}{\\t}g;
    $str =~ s{"}{\\"}g;
    $str =~ s{\$}{\\\$}g;
    return $str;
}


#
# methods
#

sub is_strict { $_[0]->strict }


sub indent {
    $_[0]->indent_space x $_[0]->indent_depth;
}


sub code {
    join( '', grep { defined $_ } @{ $_[0]->lines } );
}


sub frame_and_line {
    my ( $self ) = @_;
    ( "'" . $self->framename . "'", $self->current_line );
}


sub write_lines {
    my ( $self, $lines, $idx ) = @_;
    my $code = '';

    $idx = $self->current_line unless defined $idx;

    for my $line ( split/\n/, $lines ) {
        $code .= $self->indent . $line . "\n";
    }

    $self->lines->[ $idx ] .= $code;
}


sub write_code {
    my ( $self, $code, $idx ) = @_;
    $idx = $self->current_line unless defined $idx;
    $self->lines->[ $idx ] .= $code;
}


sub reset_line {
    my ( $self, $idx ) = @_;
    $idx = $self->current_line unless defined $idx;
    $self->lines->[ $idx ] = '';
}


sub optimize_to_print {
    my ( $self, $type ) = @_;
    my $ops = $self->ops->[ $self->current_line + 1 ];

    return unless $ops;
    return unless ( $ops->[0] eq 'print' );

    if ( $type eq 'num' ) { # currently num only
        $ops->[0] = 'print_raw';
    }

}


#
# functions called in booster code
#

sub neat {
    if ( defined $_[0] ) {
        if ( $_[0] =~ /^-?[.0-9]+$/ ) {
            return $_[0];
        }
        else {
            return "'" . $_[0] . "'";
        }
    }
    else {
        'nil';
    }
}


sub call {
    my ( $st, $frame, $line, $flag, $proc, @args ) = @_;
    my $obj = shift @args if ( $flag );
    my $ret;

    if ( $flag ) { # method call ... fetch() doesn't use methodcall for speed
        unless ( defined $obj ) {
            warn_in_booster( $st, $frame, $line, "Use of nil to invoke method %s", $proc );
        }
        else {
            local $SIG{__DIE__}; # oops
            local $SIG{__WARN__};
            $ret = eval { $obj->$proc( @args ) };
        }
    }
    else { # function call
            local $SIG{__DIE__}; # oops
            local $SIG{__WARN__};
            $ret = eval { $proc->( @args ) };
    }

    $ret;
}


use Text::Xslate::PP::Type::Pair;
use Text::Xslate::PP::Type::Array;
use Text::Xslate::PP::Type::Hash;

use constant TX_ENUMERABLE => 'Text::Xslate::PP::Type::Array';
use constant TX_KV         => 'Text::Xslate::PP::Type::Hash';

my %builtin_method = (
    size    => [0, TX_ENUMERABLE],
    join    => [1, TX_ENUMERABLE],
    reverse => [0, TX_ENUMERABLE],

    keys    => [0, TX_KV],
    values  => [0, TX_KV],
    kv      => [0, TX_KV],
);

sub methodcall {
    my ( $st, $frame, $line, $method, $invocant, @args ) = @_;

    my $retval;
    if(Scalar::Util::blessed($invocant)) {
        if($invocant->can($method)) {
            $retval = eval { $invocant->$method(@args) };
            if($@) {
                error_in_booster( $st, $frame, $line, "%s" . "\t...", $@ );
            }
            return $retval;
        }
        # fallback
    }

    if(!defined $invocant) {
        warn_in_booster( $st, $frame, $line, "Use of nil to invoke method %s", $method );
    }
    else {
        my $bm = $builtin_method{$method} || return undef;

        my($nargs, $klass) = @{$bm};
        if(@args != $nargs) {
            error_in_booster($st, $frame, $line,
                "Builtin method %s requres exactly %d argument(s), "
                . "but supplied %d",
                $method, $nargs, scalar @args);
            return undef;
         }

         $retval = eval {
            $klass->new($invocant)->$method(@args);
        };
    }

    return $retval;
}


sub fetch {
    my ( $st, $var, $key, $frame, $line ) = @_;

    if ( Scalar::Util::blessed $var ) {
        return call( $st, $frame, $line, 1, $key, $var );
    }
    elsif ( ref $var eq 'HASH' ) {
        if ( defined $key ) {
            return $var->{ $key };
        }
        else {
            warn_in_booster( $st, $frame, $line, "Use of nil as a field key" );
        }
    }
    elsif ( ref $var eq 'ARRAY' ) {
        if ( defined $key and $key =~ /[-.0-9]/ ) {
            return $var->[ $key ];
        }
        else {
            warn_in_booster( $st, $frame, $line, "Use of %s as an array index", neat( $key ) );
        }
    }
    elsif ( defined $var ) {
        error_in_booster( $st, $frame, $line, "Cannot access %s (%s is not a container)", neat($key), neat($var) );
    }
    else {
        warn_in_booster( $st, $frame, $line, "Use of nil to access %s", neat( $key ) );
    }

    return;
}


sub check_itr_ar {
    my ( $st, $ar, $frame, $line ) = @_;

    unless ( $ar and ref $ar eq 'ARRAY' ) {
        if ( defined $ar ) {
            error_in_booster( $st, $frame, $line, "Iterator variables must be an ARRAY reference, not %s", neat( $ar ) );
        }
        else {
            warn_in_booster( $st, $frame, $line, "Use of nil to iterate" );
        }
        $ar = [];
    }

    return $ar;
}


sub cond_and {
    my ( $value, $subref ) = @_;
    $value ? $subref->() : $value;
}


sub cond_or {
    my ( $value, $subref ) = @_;
    !$value ? $subref->() : $value;
}


sub cond_dand {
    my ( $value, $subref ) = @_;
    defined $value ? $subref->() : $value;
}


sub cond_dor {
    my ( $value, $subref ) = @_;
    !(defined $value) ? $subref->() : $value;
}


sub cond_eq {
    my ( $sa, $sb ) = @_;
    if ( defined $sa and defined $sb ) {
        return $sa eq $sb;
    }

    if ( defined $sa ) {
        return defined $sb && $sa eq $sb;
    }
    else {
        return !defined $sb;
    }
}


sub cond_ne {
    !cond_eq( @_ );
}


sub push_pad {
    push @{ $_[0] }, $_[1];
    $_[0];
}


sub local_s {
    my( $st, $key, $newval ) = @_;
    my $vars   = $st->{vars};
    my $oldval = delete $vars->{$key};

    require Scope::Guard;

    push @{ $st->{local_stack} ||= [] }, Scope::Guard->new(
        exists $vars->{$key}
            ? sub {  $vars->{$key} = $oldval; return }
            : sub { delete $vars->{$key};     return }
    );

    $vars->{$key} = $newval;
}


sub is_verbose {
    my $v = $_[0]->self->{ verbose };
    defined $v ? $v : Text::Xslate::PP::Opcode::TX_VERBOSE_DEFAULT;
}


sub warn_in_booster {
    my ( $st, $frame, $line, $fmt, @args ) = @_;
    if( is_verbose( $st ) > Text::Xslate::PP::Opcode::TX_VERBOSE_DEFAULT ) {
        if ( defined $line ) {
            $st->{ pc } = $line;
            $st->frame->[ $st->current_frame ]->[ Text::Xslate::PP::Opcode::TXframe_NAME ] = $frame;
        }
        Carp::carp( sprintf( $fmt, @args ) );
    }
}


sub error_in_booster {
    my ( $st, $frame, $line, $fmt, @args ) = @_;
    if( is_verbose( $st ) >= Text::Xslate::PP::Opcode::TX_VERBOSE_DEFAULT ) {
        if ( defined $line ) {
            $st->{ pc } = $line;
            $st->frame->[ $st->current_frame ]->[ Text::Xslate::PP::Opcode::TXframe_NAME ] = $frame;
        }
        Carp::carp( sprintf( $fmt, @args ) );
    }
}


no Any::Moose;
__PACKAGE__->meta->make_immutable;
1;
__END__

=head1 NAME

Text::Xslate::PP::Booster - Text::Xslate::PP booster

=head1 SYNOPSIS

    # When you set a true value to the environmental variable XSLATE_PP_BOOST,
    # this module is used in Text::Xslate::PP.
    
    # If you want to check created codes, you can use it directly.
    use Text::Xslate::PP;
    use Text::Xslate::PP::Booster;
    
    my $tx      = Text::Xslate->new();
    my $booster = Text::Xslate::PP::Booster->new( { strict => 0 } );
    
    my $optext  = q{<: $value :>};
    my $code    = $booster->opcode_to_perlcode_string( $tx->_compiler->compile( $optext ) );
    my $coderef = $booster->opcode_to_perlcode( $tx->_compiler->compile( $optext ) );
    # $coderef takes a Text::Xslate::PP::State object

=head1 DESCRIPTION

This module boosts L<Text::Xslate::PP> runtime speed.

Text::Xslate::PP is very very slow, you know. Example:

    > XSLATE=pp perl benchmark/others.pl
    
    Text::Xslate/0.1019
    Text::MicroTemplate/0.11
    Text::ClearSilver/0.10.5.4
    Template/2.22
    ...
             Rate xslate     tt     mt     cs
    xslate  119/s     --   -58%   -84%   -95%
    tt      285/s   139%     --   -61%   -88%
    mt      725/s   507%   154%     --   -69%
    cs     2311/s  1835%   711%   219%     --

All right, slower than template-toolkit!
But if you set a true value to the environmental variable L<XSLATE_PP_BOOST>,

    > XSLATE=pp XSLATE_PP_BOOST=1 perl benchmark/others.pl
    
             Rate     tt     mt xslate     cs
    tt      288/s     --   -60%   -62%   -86%
    mt      710/s   147%     --    -5%   -66%
    xslate  749/s   160%     5%     --   -65%
    cs     2112/s   634%   197%   182%     --

Text::Xslate::PP becomes to be faster!

And L<XSLATE_PP_BOOST=2> may be much faster (no strict error handling compatibility mode).


=head1 APIs

=head2 new

Constructor.

  $booster = Text::Xslate::PP::Booster->new( $opts );

It can take a hash reference option:

=over

=item strict

If set a true value, it enhances a compatibility of Text::Xslate error handling
at the cost of speed a bit. Default by true.

=back

=head2 opcode_to_perlcode

Takes a virtual machine code created by L<Text::Xslate::Compiler>,
and returns a code reference.

  $coderef = $booster->opcode_to_perlcode( $ops );

The code reference takes C<Text::Xslate::PP::State> object in Xslate runtime processes.
Don't execute this code reference directly.

=head2 opcode_to_perlcode_string

Takes a virtual machine code created by C<Text::Xslate::Compiler>,
and returns a perl subroutine code text.

  $str = $booster->opcode_to_perlcode_string( $ops );

=head1 ABOUT BOOST CODE

C<Text::Xslate::PP::Booster> creates a code reference from a virtual machine code.

    $ENV{ XSLATE_PP_BOOST } = 1;
    
    $tx->render_string( <<'CODE', {} );
    : macro foo -> $arg {
        Hello <:= $arg :>!
    : }
    : foo($value)
    CODE

Firstly the template data is converted to opcodes:

    pushmark
    fetch_s "value"
    push
    macro "foo"
    macrocall
    print
    end
    macro_begin "foo"
    print_raw_s "    Hello "
    fetch_lvar 0
    print
    print_raw_s "!\n"
    macro_end

And the booster converted them into a perl subroutine code (strict option set in this case).

    sub { no warnings 'recursion';
        my ( $st ) = $_[0];
        my ( $sv, $st2, $pad, %macro, $depth );
        my $output = '';
        my $vars   = $st->{ vars };

        $pad = [ [ ] ];

        # macro

        $macro{'foo'} = $st->{ booster_macro }->{'foo'} ||= sub {
            my ( $st, $pad ) = @_;
            my $vars = $st->{ vars };
            my $output = '';

            Carp::croak('Macro call is too deep (> 100) at "foo"') if ++$depth > 100;

            $output .= "        Hello ";

            $sv = $pad->[ -1 ]->[ 0 ];

            if ( Scalar::Util::blessed( $sv ) and $sv->isa('Text::Xslate::EscapedString') ) {
                $output .= $sv;
            }
            elsif ( defined $sv ) {
                if ( $sv =~ /[&<>"']/ ) {
                    $sv =~ s/&/&amp;/g;
                    $sv =~ s/</&lt;/g;
                    $sv =~ s/>/&gt;/g;
                    $sv =~ s/"/&quot;/g;
                    $sv =~ s/'/&#39;/g;
                }
                $output .= $sv;
            }
            else {
                warn_in_booster( $st, 'foo', 10, "Use of nil to be printed" );
            }

            $output .= "!\n";

            $depth--;
            pop( @$pad );

            $output;
        };


        # process start

        $output .= $macro{'foo'}->( $st, push_pad( $pad, [ $vars->{ "value" } ] ) );

        # process end

        $st->{ output } = $output;
    }

So it makes the runtime speed much faster.
Of course, its initial converting process takes a little cost of CPU and time.

=head1 CAVEAT

Boost codes have the error handling compatibility as possible.
But if you set C<strict> option false, it is different from the original behavior,
especially the line where an error occurs becomes uncertain.

=head1 SEE ALSO

L<Text::Xslate::PP>

=head1 AUTHOR

Makamaka Hannyaharamitu E<lt>makamaka at cpan.orgE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2010 by Makamaka Hannyaharamitu (makamaka).

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
