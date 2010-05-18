package Text::Xslate::PP::Booster;

use Mouse;
#use strict;
use Data::Dumper;
use Carp ();
use Scalar::Util ();

use Text::Xslate::PP::Const;

our $VERSION = '0.1017';

my %CODE_MANIP = ();
my $TX_OPS = \%Text::Xslate::OPS;


has indent_depth => ( is => 'rw', default => 1 );

has indent_space => ( is => 'rw', default => '    ' );

has lines => ( is => 'rw', default => sub { []; } );

has ops => ( is => 'rw', default => sub { []; } );

has current_line => ( is => 'rw', default => 0 );

has exprs => ( is => 'rw' );

has sa => ( is => 'rw' );

has sb => ( is => 'rw' );

has lvar => ( is => 'rw', default => sub { []; } );

#
# public APIs
#

sub convert_opcode {
    my ( $class, $proto, $parent ) = @_;
    my $len = scalar( @$proto );

    my $state = $class->new(
        ops => $proto,
    );

    if ( $parent ) { # 引き継ぐ
        $state->sa( $parent->sa );
        $state->sb( $parent->sb );
        $state->lvar( [ @{ $parent->lvar } ] );
    }

    # コード生成
    my $i = 0;

    while ( $state->current_line < $len ) {
        my $pair = $proto->[ $i ];

        unless ( $pair and ref $pair eq 'ARRAY' ) {
            Carp::croak( sprintf( "Oops: Broken code found on [%d]",  $i ) );
        }

        my ( $opname, $arg, $line ) = @$pair;
        my $opnum = $TX_OPS->{ $opname };

        unless ( $CODE_MANIP{ $opname } ) {
            Carp::croak( sprintf( "Oops: opcode '%s' is not yet implemented on Booster", $opname ) );
        }

        my $manip  = $CODE_MANIP{ $opname };

        if ( my $proc = $state->{ proc }->{ $i } ) {

            if ( $proc->{ skip } ) {
                $state->current_line( ++$i );
                next;
            }

        }

        $manip->( $state, $arg, defined $line ? $line : '' );

        $state->current_line( ++$i );
    }

    return $state;
}


sub opcode2perlcode_str {
    my ( $class, $proto ) = @_;

    #my $tx = Text::Xslate->new;
    #print $tx->_compiler->as_assembly( $proto );

    my $state = $class->convert_opcode( $proto );

    # 書き出し

    my $perlcode =<<'CODE';
sub { no warnings 'recursion';
    my ( $st ) = $_[0];
    my ( $sa, $sb, $sv, $st2, $pad, %macro, $depth );
    my $output = '';
    my $vars  = $st->{ vars };

    $pad = [ [ ] ];

CODE

    if ( $state->{ macro_mem } ) {
        for ( reverse @{ $state->{ macro_mem } } ) {
            push @{ $state->{ macro_lines } }, splice( @{ $state->{ lines } },  $_->[0], $_->[1] );
        }

        $perlcode .=<<'CODE';
    # macro
CODE

        $perlcode .= join ( '', grep { defined } @{ $state->{ macro_lines } } );
    }

    $perlcode .=<<'CODE';

    # process start

CODE

    $perlcode .= join( '', grep { defined } @{ $state->{lines} } );


$perlcode .=<<'CODE';
    $st->{ output } = $output;
}
CODE

    return $perlcode;
}


sub opcode2perlcode {
    my ( $class, $proto, $codes ) = @_;

    my $perlcode = opcode2perlcode_str( @_ );

    # TEST
    print "$perlcode\n" if $ENV{ BOOST_DISP };

    my $evaled_code = eval $perlcode;

    die $@ unless $evaled_code;

    return $evaled_code;
}


#
#
#

$CODE_MANIP{ 'noop' } = sub {
};


$CODE_MANIP{ 'move_to_sb' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sb( $state->sa );
};


$CODE_MANIP{ 'move_from_sb' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( $state->sb );

    if ( $state->{ within_cond } ) {
        $state->write_lines( sprintf( '$sa = %s;', $state->sb ) );
    }

};


$CODE_MANIP{ 'save_to_lvar' } = sub {
    my ( $state, $arg, $line ) = @_;
    my $v = sprintf( '( $pad->[ -1 ]->[ %s ] = %s )', $arg, $state->sa );
    $state->lvar->[ $arg ] = $state->sa;
    $state->sa( $v );

    my $op = $state->{ ops }->[ $state->current_line + 1 ];

    unless ( $op and $op->[0] =~ /^(?:print|and|or|dand|dor|push)/ ) { # ...
        $state->write_lines( sprintf( '%s;', $v )  );
    }

};


$CODE_MANIP{ 'load_lvar_to_sb' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sb( $state->lvar->[ $arg ] );
};


$CODE_MANIP{ 'push' } = sub {
    my ( $state, $arg, $line ) = @_;
    push @{ $state->{ SP }->[ -1 ] }, $state->sa;
};


$CODE_MANIP{ 'pushmark' } = sub {
    my ( $state, $arg, $line ) = @_;
    push @{ $state->{ SP } }, [];
};


$CODE_MANIP{ 'nil' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( 'undef' );
};


$CODE_MANIP{ 'literal' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( '"' . escape( $arg ) . '"' );
};


$CODE_MANIP{ 'literal_i' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( $arg );
    $state->optimize_to_print( 'num' );
    $state->optimize_to_expr();
};


$CODE_MANIP{ 'fetch_s' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( '$vars->{ "%s" }', escape( $arg ) ) );
};


$CODE_MANIP{ 'fetch_lvar' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( '$pad->[ -1 ]->[ %s ]', $arg ) );
};


$CODE_MANIP{ 'fetch_field' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( 'fetch( $st, %s, %s )', $state->sb(), $state->sa() ) );
};


$CODE_MANIP{ 'fetch_field_s' } = sub {
    my ( $state, $arg, $line ) = @_;
    my $sv = $state->sa();
    $state->sa( sprintf( 'fetch( $st, %s, "%s" )', $sv, escape( $arg ) ) );
};


$CODE_MANIP{ 'print_raw' } = sub {
    my ( $state, $arg, $line ) = @_;
    my $sv = $state->sa();
    $state->write_lines( sprintf('$output .= %s;', $sv) );
    $state->write_code( "\n" );
};


$CODE_MANIP{ 'print_raw_s' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->write_lines( sprintf('$output .= "%s";', escape( $arg ) ) );
    $state->write_code( "\n" );
};


$CODE_MANIP{ 'print' } = sub {
    my ( $state, $arg, $line ) = @_;
    my $sv = $state->sa();

    $state->write_lines( sprintf( <<'CODE', $sv) );
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
        $sv =~ s/'/&#39;/g;
    }
    $output .= $sv;
}
else {
    warn_in_booster( $st, "Use of nil to be printed" );
}
CODE

    $state->write_code( "\n" );
};


$CODE_MANIP{ 'include' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->write_lines( sprintf( <<'CODE', $state->sa ) );
$st2 = Text::Xslate::PP::tx_load_template( $st->self, %s );
Text::Xslate::PP::tx_execute( $st2, undef, $vars );
$output .= $st2->{ output };

CODE

};


$CODE_MANIP{ 'for_start' } = sub {
    my ( $state, $arg, $line ) = @_;

    push @{ $state->{ for_level } }, {
        stack_id => $arg,
        ar       => $state->sa,
    };
};


$CODE_MANIP{ 'for_iter' } = sub {
    my ( $state, $arg, $line ) = @_;

    $state->{ loop }->{ $state->current_line } = 1; # marked

    my $stack_id = $state->{ for_level }->[ -1 ]->{ stack_id };
    my $ar       = $state->{ for_level }->[ -1 ]->{ ar };

    $state->write_lines( sprintf( 'for ( @{ %s } ) {', $ar ) );
    $state->write_code( "\n" );

    $state->indent_depth( $state->indent_depth + 1 );

    $state->write_lines( sprintf( '$pad->[ -1 ]->[ %s ] = $_;', $state->sa() ) );
    $state->write_code( "\n" );
};


$CODE_MANIP{ 'add' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( '( %s + %s )', $state->sb(), $state->sa() ) );
    $state->optimize_to_print( 'num' );
};


$CODE_MANIP{ 'sub' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( '( %s - %s )', $state->sb(), $state->sa() ) );
    $state->optimize_to_print( 'num' );
};


$CODE_MANIP{ 'mul' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( '( %s * %s )', $state->sb(), $state->sa() ) );
    $state->optimize_to_print( 'num' );
};


$CODE_MANIP{ 'div' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( '( %s / %s )', $state->sb(), $state->sa() ) );
    $state->optimize_to_print( 'num' );
};


$CODE_MANIP{ 'mod' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( '( %s %% %s )', $state->sb(), $state->sa() ) );
    $state->optimize_to_print( 'num' );
};


$CODE_MANIP{ 'concat' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( '( %s . %s )', $state->sb(), $state->sa() ) );
};


$CODE_MANIP{ 'filt' } = sub {
    my ( $state, $arg, $line ) = @_;
    my $i = $state->{ i };
    my $ops = $state->{ ops };

    $state->sa( sprintf('( eval { %s->( %s ) } )', $state->sa, $state->sb ) );
};


$CODE_MANIP{ 'and' } = sub {
    my ( $state, $arg, $line ) = @_;
    return check_logic( $state, $state->current_line, $arg, 'and' );
};


$CODE_MANIP{ 'dand' } = sub {
    my ( $state, $arg, $line ) = @_;
    return check_logic( $state, $state->current_line, $arg, 'dand' );
};


$CODE_MANIP{ 'or' } = sub {
    my ( $state, $arg, $line ) = @_;
    return check_logic( $state, $state->current_line, $arg, 'or' );
};


$CODE_MANIP{ 'dor' } = sub {
    my ( $state, $arg, $line ) = @_;
    return check_logic( $state, $state->current_line, $arg, 'dor' );
};


$CODE_MANIP{ 'not' } = sub {
    my ( $state, $arg, $line ) = @_;
    my $sv = $state->sa();
    $state->sa( sprintf( '( !%s )', $sv ) );
};


$CODE_MANIP{ 'plus' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( '+ %s', $state->sa ) );
};


$CODE_MANIP{ 'minus' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( '- %s', $state->sa ) );
};


$CODE_MANIP{ 'eq' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( 'cond_eq( %s, %s )', $state->sb(), $state->sa() ) );
};


$CODE_MANIP{ 'ne' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( 'cond_ne( %s, %s )', $state->sb(), $state->sa() ) );
};



$CODE_MANIP{ 'lt' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( '( %s < %s )', $state->sb(), $state->sa() ) );
};


$CODE_MANIP{ 'le' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( '( %s <= %s )', $state->sb(), $state->sa() ) );
};


$CODE_MANIP{ 'gt' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( '( %s > %s )', $state->sb(), $state->sa() ) );
};


$CODE_MANIP{ 'ge' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( sprintf( '( %s >= %s )', $state->sb(), $state->sa() ) );
};


$CODE_MANIP{ 'macrocall' } = sub {
    my ( $state, $arg, $line ) = @_;
    my $ops  = $state->ops;
    $state->optimize_to_print( 'num' );

    $state->sa( sprintf( '$macro{\'%s\'}->(%s)',
        $state->sa(),
        sprintf( 'push @{ $pad }, [ %s ]', join( ', ', @{ pop @{ $state->{ SP } } } ) )
    ) );
};


$CODE_MANIP{ 'macro_begin' } = sub {
    my ( $state, $arg, $line ) = @_;

    $state->{ macro_begin } = $state->current_line;

    $state->write_lines( sprintf( '$macro{\'%s\'} = sub {', $arg ) );
    $state->indent_depth( $state->indent_depth + 1 );

    $state->write_lines(
        sprintf( q{Carp::croak('Macro call is too deep (> 100) at "%s"') if ++$depth > 100;}, $arg )
    );

    $state->write_lines( sprintf( 'my $output;' ) );
};


$CODE_MANIP{ 'macro_end' } = sub {
    my ( $state, $arg, $line ) = @_;

    $state->write_lines( sprintf( '$depth--;' ) );
    $state->write_lines( sprintf( 'pop( @$pad );' ) );
    $state->write_code( "\n" );
    $state->write_lines( sprintf( '$output;' ) );

    $state->indent_depth( $state->indent_depth - 1 );

    $state->write_lines( sprintf( "};\n" ) );

    push @{ $state->{ macro_mem } }, [ $state->{ macro_begin }, $state->current_line ];
};


$CODE_MANIP{ 'macro' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa( $arg );
};


$CODE_MANIP{ 'function' } = sub { # not yet implemebted
    my ( $state, $arg, $line ) = @_;
    $state->sa(
        sprintf('$st->function->{ %s }', $arg )
    );
};


$CODE_MANIP{ 'funcall' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa(
        sprintf('call( $st, 0, %s, %s )', $state->sa, join( ', ', @{ pop @{ $state->{ SP } } } ) )
    );
};


$CODE_MANIP{ 'methodcall_s' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->sa(
        sprintf('methodcall( $st, "%s", %s )', $arg, join( ', ', @{ pop @{ $state->{ SP } } } ) )
    );
};


$CODE_MANIP{ 'goto' } = sub {
    my ( $state, $arg, $line ) = @_;
    my $i = $state->current_line;

    if ( delete $state->{ loop }->{ $i + $arg + 1 } ) { # forブロックを閉じる
        $state->indent_depth( $state->indent_depth - 1 );
        pop @{ $state->{ for_level } };
        $state->write_lines( '}' );
    }
    else {
        die "invalid goto op";
    }

    $state->write_code( "\n" );
};


$CODE_MANIP{ 'depend' } = sub {
};


$CODE_MANIP{ 'end' } = sub {
    my ( $state, $arg, $line ) = @_;
    $state->write_lines( "# process end" );
};

#
#
#


sub check_logic {
    my ( $state, $i, $arg, $type ) = @_;
    my $ops = $state->ops;
    my $type_store = $type;

    my $next_opname = $ops->[ $i + $arg ]->[ 0 ] || '';

    if ( $next_opname =~ /and|or/ ) { # &&, ||
        $type = $type eq 'and'  ? ' && '
              : $type eq 'dand' ? 'defined( %s )'
              : $type eq 'or'   ? ' || '
              : $type eq 'dor'  ? '!(defined( %s ))'
              : die
              ;
        my $pre_exprs = $state->exprs || '';
        $state->exprs( $pre_exprs . $state->sa() . $type ); # 保存
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

    if ( $opname eq 'goto' and $oparg > 0 ) { # if-elseか三項演算子？
        my $if_block_start   = $i + 1;                  # ifブロック開始行
        my $if_block_end     = $i + $arg - 2;           # ifブロック終了行 - goto分も引く
        my $else_block_start = $i + $arg;               # elseブロック開始行
        my $else_block_end   = $i + $arg + $oparg - 2;  # elseブロック終了行 - goto分を引く

        my ( $sa_1st, $sa_2nd );

        $state->{ proc }->{ $i + $arg - 1 }->{ skip } = 1; # goto処理飛ばす

        for ( $if_block_start .. $if_block_end ) {
            $state->{ proc }->{ $_ }->{ skip } = 1; # スキップ処理
        }

        my $st_1st = ref($state)->convert_opcode( [ @{ $ops }[ $if_block_start .. $if_block_end ] ] );

        my $code = $st_1st->code;
        if ( $code and $code !~ /^\n+$/ ) {
            my $expr = $state->sa;
            $expr = ( $state->exprs || '' ) . $expr; # 前に式があれば加える
            $state->write_lines( sprintf( 'if ( %s ) {' , sprintf( $type, $expr ) ) );
            $state->exprs( '' );
            $state->write_lines( $code );
            $state->write_lines( sprintf( '}' ) );
        }
        else { # 三項演算子として扱う
            $sa_1st = $st_1st->sa;
        }

        if ( $else_block_end >= $else_block_start ) {

            for (  $else_block_start .. $else_block_end ) { # 2
                $state->{ proc }->{ $_ }->{ skip } = 1; # スキップ処理
            }

            my $st_2nd = ref($state)->convert_opcode( [ @{ $ops }[ $else_block_start .. $else_block_end ] ] );

            my $code = $st_2nd->code;

            if ( $code and $code !~ /^\n+$/ ) {
                $state->write_lines( sprintf( 'else {' ) );
                $state->write_lines( $code );
                $state->write_lines( sprintf( '}' ) );
            }
            else { # 三項演算子として扱う
                $sa_2nd = $st_2nd->sa;
            }

        }

        if ( defined $sa_1st and defined $sa_2nd ) {
            my $expr = $state->sa;
            $expr = ( $state->exprs || '' ) . $expr; # 前に式があれば加える
            $state->sa( sprintf( '(%s ? %s : %s)', sprintf( $type, $expr ), $sa_1st, $sa_2nd ) );
        }
        else {
            $state->write_code( "\n" );
        }

    }
    elsif ( $opname eq 'goto' and $oparg < 0 ) { # while
        my $while_block_start   = $i + 1;                  # whileブロック開始行
        my $while_block_end     = $i + $arg - 2;           # whileブロック終了行 - goto分も引く

        for ( $while_block_start .. $while_block_end ) {
            $state->{ proc }->{ $_ }->{ skip } = 1; # スキップ処理
        }

        $state->{ proc }->{ $i + $arg - 1 }->{ skip } = 1; # goto処理飛ばす

        my $st_wh = ref($state)->convert_opcode( [ @{ $ops }[ $while_block_start .. $while_block_end ] ] );

        my $expr = $state->sa;
        $expr = ( $state->exprs || '' ) . $expr; # 前に式があれば加える
        $state->write_lines( sprintf( 'while ( %s ) {' , sprintf( $type, $expr ) ) );
        $state->exprs( '' );
        $state->write_lines( $st_wh->code );
        $state->write_lines( sprintf( '}' ) );

        $state->write_code( "\n" );
    }
    elsif ( logic_is_max_main( $ops, $i, $arg ) ) { # min, max

        for ( $i + 1 .. $i + 2 ) {
            $state->{ proc }->{ $_ }->{ skip } = 1; # スキップ処理
        }

        $state->sa( sprintf( '%s ? %s : %s', $state->sa, $state->sb, $state->lvar->[ $ops->[ $i + 1 ]->[ 1 ] ] ) );
    }
    else { # それ以外の処理

        my $true_start = $i + 1;
        my $true_end   = $i + $arg - 1; # 次の行までで完成のため、1足す
        my $false_line = $i + $arg;

            $false_line--; # 出力される場合は省略、falseで設定される値もない

        for ( $true_start .. $true_end ) {
            $state->{ proc }->{ $_ }->{ skip } = 1; # スキップ処理
        }

        my $st_true  = ref($state)->convert_opcode( [ @{ $ops }[ $true_start .. $true_end ] ], $state );

        my $expr = $state->sa;
        $expr = ( $state->exprs || '' ) . $expr; # 前に式があれば加える

            $type = $type_store eq 'and'  ? 'cond_and'
                  : $type_store eq 'or'   ? 'cond_or'
                  : $type_store eq 'dand' ? 'cond_dand'
                  : $type_store eq 'dor'  ? 'cond_dor'
                  : die
                  ;

$state->sa( sprintf( <<'CODE', $type, $expr, $st_true->sa ) );
%s( %s, sub {
%s
}, )
CODE

    }

}


sub logic_is_max_main {
    my ( $ops, $i, $arg ) = @_;
        $ops->[ $i     ]->[ 0 ] eq 'or'
    and $ops->[ $i + 1 ]->[ 0 ] eq 'load_lvar_to_sb'
    and $ops->[ $i + 2 ]->[ 0 ] eq 'move_from_sb'
    and $arg == 2
}


#
# methods
#


sub code {
    join( '', grep { defined $_ } @{ $_[0]->lines } );
}


sub write_lines {
    my ( $state, $lines, $idx ) = @_;
    my $code = '';

    $idx = $state->current_line unless defined $idx;

    for my $line ( split/\n/, $lines ) {
        $code .= $state->indent . $line . "\n";
    }

    $state->lines->[ $idx ] .= $code;
}


sub write_code {
    my ( $state, $code, $idx ) = @_;
    $idx = $state->current_line unless defined $idx;
    $state->lines->[ $idx ] .= $code;
}


sub reset_line {
    my ( $state, $idx ) = @_;
    $idx = $state->current_line unless defined $idx;
    $state->lines->[ $idx ] = '';
}


sub optimize_to_print {
    my ( $state, $type ) = @_;
    my $ops = $state->ops->[ $state->current_line + 1 ];

    return unless $ops;
    return unless ( $ops->[0] eq 'print' );

    if ( $type eq 'num' ) {
        $ops->[0] = 'print_raw';
    }

}


sub optimize_to_expr {
    my ( $state ) = @_;
    my $ops = $state->ops->[ $state->current_line + 1 ];

    return unless $ops;
    return unless ( $ops->[0] eq 'goto' );

    $state->write_lines( sprintf( '$sa = %s;', $state->sa ) );
    $state->sa( '$sa' );

}


#
# utils
#

sub indent {
    $_[0]->indent_space x $_[0]->indent_depth;
}


sub escape {
    my $str = $_[0];
    $str =~ s{\\}{\\\\}g;
    $str =~ s{\n}{\\n}g;
    $str =~ s{\t}{\\t}g;
    $str =~ s{"}{\\"}g;
    $str =~ s{\$}{\\\$}g;
    return $str;
}


#
# called in booster code
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
    my ( $st, $flag, $proc, @args ) = @_;
    my $obj = shift @args if ( $flag );
    my $ret;

    if ( $flag ) { # method call ... fetch() doesn't use methodcall for speed
        unless ( defined $obj ) {
            warn_in_booster( $st, "Use of nil to invoke method %s", $proc );
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
    my ( $st, $method, $invocant, @args ) = @_;

    my $retval;
    if(Scalar::Util::blessed($invocant)) {
        if($invocant->can($method)) {
            $retval = eval { $invocant->$method(@args) };
            if($@) {
                error_in_booster($st, "%s" . "\t...", $@);
            }
            return $retval;
        }
        # fallback
    }

    if(!defined $invocant) {
        warn_in_booster($st, "Use of nil to invoke method %s", $method);
    }
    else {
        my $bm = $builtin_method{$method} || return undef;

        my($nargs, $klass) = @{$bm};
        if(@args != $nargs) {
            error_in_booster($st,
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
    my ( $st, $var, $key ) = @_;
    my $ret;

    if ( Scalar::Util::blessed $var ) {
        $ret = call( $st, 1, $key, $var );
    }
    elsif ( ref $var eq 'HASH' ) {
        if ( defined $key ) {
            $ret = $var->{ $key };
        }
        else {
            warn_in_booster( $st, "Use of nil as a field key" );
        }
    }
    elsif ( ref $var eq 'ARRAY' ) {
        if ( defined $key and $key =~ /[-.0-9]/ ) {
            $ret = $var->[ $key ];
        }
        else {
            warn_in_booster( $st, "Use of %s as an array index", neat( $key ) );
        }
    }
    elsif ( defined $var ) {
        error_in_booster( $st, "Cannot access %s (%s is not a container)", neat($key), neat($var) );
    }
    else {
        print Dumper $var;
        warn_in_booster( $st, "Use of nil to access %s", neat( $key ) );
    }

    return $ret;
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


sub is_verbose {
    my $v = $_[0]->self->{ verbose };
    defined $v ? $v : Text::Xslate::PP::Opcode::TX_VERBOSE_DEFAULT;
}


sub warn_in_booster {
    my ( $st, $fmt, @args ) = @_;
    if( is_verbose( $st ) > Text::Xslate::PP::Opcode::TX_VERBOSE_DEFAULT ) {
        Carp::carp( sprintf( $fmt, @args ) );
    }
}


sub error_in_booster {
    my ( $st, $fmt, @args ) = @_;
    if( is_verbose( $st ) >= Text::Xslate::PP::Opcode::TX_VERBOSE_DEFAULT ) {
        Carp::carp( sprintf( $fmt, @args ) );
    }
}


1;
__END__


=head1 NAME

Text::Xslate::PP::Booster - Text::Xslate::PP speed up!!!!

=head1 SYNOPSYS

    use Text::Xslate::PP;
    use Text::Xslate::PP::Booster;
    
    my $tx      = Text::Xslate->new();
    my $code    = Text::Xslate::PP::Booster->opcode2perlcode_str( $tx->_compiler->compile( ... ) );
    my $coderef = Text::Xslate::PP::Booster->opcode2perlcode( $tx->_compiler->compile( ... ) );

=head1 DESCRIPTION

This module is called by Text::Xslate::PP internally.

=head1 SEE ALSO

L<Text::Xslate::PP>

=head1 AUTHOR

Makamaka Hannyaharamitu E<lt>makamaka at cpan.orgE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2010 by Makamaka Hannyaharamitu (makamaka).

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
