use strict;
use warnings;
package Log::Dispatchouli;
# ABSTRACT: a simple wrapper around Log::Dispatch

use Carp ();
use Log::Dispatch;
use Params::Util qw(_ARRAYLIKE _HASHLIKE);
use Scalar::Util qw(blessed weaken);
use String::Flogger;
use Try::Tiny 0.04;

=method new

  my $logger = Log::Dispatchouli->new(\%arg);

This returns a new SvcLogger, which can then be called like a coderef to log
stuff.  You know.  Stuff.  Things, too, we'll log those.

Valid arguments are:

  ident      - the name of the thing logging (mandatory)
  to_self    - log to the logger object for testing; default: false
  to_file    - log to PROGRAM_NAME.YYYYMMDD in the log path; default: false
  to_stdout  - log to STDOUT; default: false
  to_stderr  - log to STDERR; default: false
  facility   - to which syslog facility to send logs; default: none
  log_pid    - if true, prefix all log entries with the pid; default: true
  fail_fatal - a boolean; if true, failure to log is fatal; default: true
  debug      - a boolean; if true, log_debug method is not a no-op
               defaults to the truth of the DISPATCHOULI_DEBUG env var

The log path is either F</tmp> or the value of the F<DISPATCHOULI_PATH> env var.

If the F<DISPATCHOULI_NOSYSLOG> env var is true, we don't log to syslog.

=cut

sub new {
  my ($class, $arg) = @_;

  my $ident = $arg->{ident}
    or Carp::croak "no ident specified when using $class";

  my $pid_prefix = exists $arg->{log_pid} ? $arg->{log_pid} : 1;

  my $self = bless {} => $class;

  my $log = Log::Dispatch->new(
    callbacks => sub {
      return( ($pid_prefix ? "[$$] " : '') . {@_}->{message})
    },
  );

  if ($arg->{to_file}) {
    require Log::Dispatch::File;
    my $log_file = File::Spec->catfile(
      ($ENV{LOG_DISPATCHOULI} || File::Spec->tempdir),
      sprintf('%s.%04u%02u%02u',
        $ident,
        ((localtime)[5] + 1900),
        sprintf('%02d', (localtime)[4] + 1),
        sprintf('%02d', (localtime)[3]),
      )
    );

    $log->add(
      Log::Dispatch::File->new(
        name      => 'logfile',
        min_level => 'debug',
        filename  => $log_file,
        mode      => 'append',
        callbacks => sub {
          # The time format returned here is subject to change. -- rjbs,
          # 2008-11-21
          return (localtime) . ' ' . {@_}->{message} . "\n"
        }
      )
    );
  }

  if ($arg->{facility} and not $ENV{LOG_DISPATCHOULI_NOSYSLOG}) {
    require Log::Dispatch::Syslog;
    $log->add(
      Log::Dispatch::Syslog->new(
        name      => 'syslog',
        min_level => 'debug',
        facility  => $arg->{facility},
        ident     => $ident,
        logopt    => 'pid',
        socket    => 'native',
        callbacks => sub {
          my %arg = @_;
          my $message = $arg{message};
          $message =~ s/\n/<LF>/g;
          return $message;
        },
      ),
    );
  }

  if ($arg->{to_self}) {
    $self->{events} = [];
    require Log::Dispatch::Array;
    $log->add(
      Log::Dispatch::Array->new(
        name      => 'self',
        min_level => 'debug',
        array     => $self->{events},
      ),
    );
  }

  DEST: for my $dest (qw(err out)) {
    next DEST unless $arg->{"to_std$dest"};
    require Log::Dispatch::Screen;
    $log->add(
      Log::Dispatch::Screen->new(
        name      => "std$dest",
        min_level => 'debug',
        stderr    => ($dest eq 'err' ? 1 : 0),
        callbacks => sub { my %arg = @_; "$arg{message}\n"; }
      ),
    );
  }

  $self->{dispatcher} = $log;
  $self->{prefix} = $arg->{prefix} || $arg->{list_name};

  $self->{debug}  = exists $arg->{debug}
                  ? $arg->{debug}
                  : $ENV{DISPATCHOULI_DEBUG};

  $self->{fail_fatal} = exists $arg->{fail_fatal} ? $arg->{fail_fatal} : 1;

  return $self;
}

=method new_tester

This returns a new logger that doesn't log.  It's useful in testing.  If no
C<ident> arg is provided, one will be generated.

=cut

sub new_tester {
  my ($class, $arg) = @_;
  $arg ||= {};

  return $class->new({
    %$arg,
    ($arg->{ident} ? () : (ident => "$$:$0")),
    to_stderr => 0,
    to_stdout => 0,
    to_file   => 0,
    facility  => undef,
  });
}

=method log

  $logger->log(@messages);

  $logger->log(\%arg, @messages);

This method uses L<String::Flogger> on the input, then logs the result.  Each
message is flogged individually, then joined with spaces.

If the first argument is a hashref, it will be used as extra arguments to
logging.  At present, all entries in the hashref are ignored.

This method can also be called as C<info>, to match other popular logging
interfaces.  B<If you want to override this method, you must override C<log>
and not C<info>>.

=cut

sub _join { shift; join q{ }, @{ $_[0] } }

sub _log_at {
  my ($self, $arg, @rest) = @_;
  shift @rest if _HASHLIKE($rest[0]); # for future expansion

  if (defined (my $prefix = $self->get_prefix)) {
    unshift @rest, "$prefix:";
  }

  my $message;
  try {
    my @flogged = map {; String::Flogger->flog($_) } @rest;
    $message    = @flogged > 1 ? $self->_join(\@flogged) : $flogged[0];

    $self->dispatcher->log(
      level   => $arg->{level},
      message => $message,
    );
  } catch {
    $message = '(no message could be logged)' unless defined $message;
    die $_ if $self->{fail_fatal};
  };

  die $message if $arg->{fatal};

  return;
}

sub log  { shift()->_log_at({ level => 'info' }, @_); }
sub info { shift()->log(@_); }

=method log_fatal

This behaves like the C<log> method, but will throw the logged string as an
exception after logging.

This method can also be called as C<fatal>, to match other popular logging
interfaces.  B<If you want to override this method, you must override
C<log_fatal> and not C<fatal>>.

=cut

sub log_fatal { shift()->_log_at({ level => 'error', fatal => 1 }, @_); }
sub fatal     { shift()->log_fatal(@_); }

=method log_debug

This behaves like the C<log> method, but will only log (at the debug level) if
the SvcLogger object has its debug property set to true.

This method can also be called as C<debug>, to match other popular logging
interfaces.  B<If you want to override this method, you must override
C<log_debug> and not C<debug>>.

=cut

sub log_debug {
  return unless $_[0]->is_debug;
  shift()->_log_at({ level => 'debug' }, @_);
}

sub debug { shift()->log_debug(@_); }

=method set_debug

  $logger->set_debug($bool);

This sets the SvcLogger's debug property, which affects the behavior of
C<log_debug>.

=cut

sub set_debug {
  return($_[0]->{debug} = ! ! $_[1]);
}

=method is_debug

C<is_debug> also exists as a read-only accessor.  Much less usefully,
C<is_info> and C<is_fatal> exist, both of which always return true.

=cut

sub is_debug { return $_[0]->{debug} }

sub is_info  { 1 }
sub is_fatal { 1 }

=method dispatcher

This returns the underlying Log::Dispatch object.  This is not the method
you're looking for.  Move along.

=cut

sub dispatcher   { $_[0]->{dispatcher} }

sub get_prefix   {
  return $_[0]->{prefix} if defined $_[0]->{prefix};
  return;
}

sub set_prefix   { $_[0]->{prefix} = $_[1] }
sub unset_prefix { undef $_[0]->{prefix} }

=method events

This method returns the arrayref of events logged to an array in memory (in the
logger).  If the logger is not logging C<to_self> this raises an exception.

=cut

sub events {
  Carp::confess "->events called on a logger not logging to self"
    unless $_[0]->{events};

  return $_[0]->{events};
}

use overload
  '&{}'    => sub { my ($self) = @_; sub { $self->log(@_) } },
  fallback => 1,
;

=head1 SEE ALSO

L<Log::Dispatch>

L<String::Flogger>

=cut

1;
