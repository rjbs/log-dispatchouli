use v5.20;
use warnings;
package Log::Fmt;
# ABSTRACT: a little parser and emitter of structured log lines

use Params::Util qw(_ARRAY0 _HASH0 _CODELIKE);
use Scalar::Util qw(refaddr);

# ASCII after SPACE but excluding = and "
my $IDENT_RE = qr{[\x21\x23-\x3C\x3E-\x7E]+};

sub _quote_string {
  my ($string) = @_;

  $string =~ s{\\}{\\\\}g;
  $string =~ s{"}{\\"}g;
  $string =~ s{\x0A}{\\n}g;
  $string =~ s{\x0D}{\\r}g;
  $string =~ s{([\pC\v])}{sprintf '\\x{%x}', ord $1}ge;

  return qq{"$string"};
}

sub _pairs_to_kvstr_aref {
  my ($self, $aref, $seen, $prefix) = @_;

  $seen //= {};

  my @kvstrs;

  KEY: for (my $i = 0; $i < @$aref; $i += 2) {
    # replace non-ident-safe chars with ?
    my $key = length $aref->[$i] ? "$aref->[$i]" : '~';
    $key =~ tr/\x21\x23-\x3C\x3E-\x7E/?/c;

    # If the prefix is "" you can end up with a pair like ".foo=1" which is
    # weird but probably best.  And that means you could end up with
    # "foo..bar=1" which is also weird, but still probably for the best.
    $key = "$prefix.$key" if defined $prefix;

    my $value = $aref->[$i+1];

    if (_CODELIKE $value) {
      $value = $value->();
    }

    if (! defined $value) {
      $value = '~missing~';
    } elsif (ref $value) {
      my $refaddr = refaddr $value;

      if ($seen->{ $refaddr }) {
        $value = $seen->{ $refaddr };
      } elsif (_ARRAY0($value)) {
        $seen->{ $refaddr } = "&$key";

        push @kvstrs, $self->_pairs_to_kvstr_aref(
          [ map {; $_ => $value->[$_] } (0 .. $#$value) ],
          $seen,
          $key,
        )->@*;

        next KEY;
      } elsif (_HASH0($value)) {
        $seen->{ $refaddr } = "&$key";

        push @kvstrs, $self->_pairs_to_kvstr_aref(
          [ $value->%{ sort keys %$value } ],
          $seen,
          $key,
        )->@*;

        next KEY;
      } else {
        $value = "$value"; # Meh.
      }
    }

    my $str = "$key="
            . ($value =~ /\A$IDENT_RE\z/
               ? "$value"
               : _quote_string($value));

    push @kvstrs, $str;
  }

  return \@kvstrs;
}

sub format_event_string {
  my ($self, $aref) = @_;

  return join q{ }, $self->_pairs_to_kvstr_aref($aref)->@*;
}

sub parse_event_string {
  my ($self, $string) = @_;

  my @result;

  HUNK: while (length $string) {
    if ($string =~ s/\A($IDENT_RE)=($IDENT_RE)(?:\s+|\z)//) {
      push @result, $1, $2;
      next HUNK;
    }

    if ($string =~ s/\A($IDENT_RE)="((\\\\|\\"|[^"])*?)"(?:\s+|\z)//) {
      my $key = $1;
      my $qstring = $2;

      $qstring =~ s{
        ( \\\\ | \\["nr] | (\\x)\{([[:xdigit:]]{1,5})\} | . )
      }
      {
          $1 eq "\\\\"        ? "\\"
        : $1 eq "\\\""        ? q{"}
        : $1 eq "\\n"         ? qq{\n}
        : $1 eq "\\r"         ? qq{\r}
        : ($2//'') eq "\\x"   ? chr(hex("0x$3"))
        :                       $1
      }gex;

      push @result, $key, $qstring; # TODO: do unescaping here
      next HUNK;
    }

    if ($string =~ s/\A(\S+)(?:\s+|\z)//) {
      push @result, 'junk', $1;
      next HUNK;
    }

    # I hope this is unreachable. -- rjbs, 2022-11-03
    push (@result, 'junk', $string, aborted => 1);
    last HUNK;
  }

  return \@result;
}

1;
