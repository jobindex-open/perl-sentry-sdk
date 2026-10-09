use Mojo::Base -strict, -signatures;

use Mojo::File;
# curfile missing in Mojolicious@^8. The dependency shall not be updated for
# the time being. For this reason `curfile` is duplicated for now.
# use lib curfile->sibling('lib')->to_string;
# See https://github.com/mojolicious/mojo/blob/4093223cae00eb516e38f2226749d2963597cca3/lib/Mojo/File.pm#L36
use lib Mojo::File->new(Cwd::realpath((caller)[1]))->sibling('lib')->to_string;

use Mock::Sentry::Hub;
use Mojo::Util 'dumper';
use Sentry::Tracing::Transaction;
use Sentry::Tracing::Span;
use Test::Spec;

describe 'Sentry::Tracing::Transaction' => sub {
  my $tx;
  my $hub;

  before each => sub {
    $hub = Mock::Sentry::Hub->new;
    $tx  = Sentry::Tracing::Transaction->new(_hub => $hub);
  };

  describe 'finish()' => sub {
    it 'does nothing unless sampled' => sub {
      $tx->sampled(0);

      is $tx->finish(),             undef;
      is $hub->captured_events->@*, 0;
    };

    it 'captures the event' => sub {
      $tx->sampled(1);
      $tx->set_name('foo');

      $tx->finish();

      is $hub->captured_events->@*,               1;
      is $hub->captured_events->[0]{transaction}, 'foo';
    };
  };

  it 'set_name()' => sub {
    $tx->set_name('bla');

    is $tx->name, 'bla';
  };

  describe 'add_span()' => sub {
    it 'adds a span' => sub {
      $tx->sampled(1);
      my $span = Sentry::Tracing::Span->new;

      $tx->add_span($span);

      is scalar $tx->spans->@*, 1;
    };

    it 'does not add a span if not sampled' => sub {
      $tx->sampled(0);
      my $span = Sentry::Tracing::Span->new;

      $tx->add_span($span);

      is scalar $tx->spans->@*, 0;
    };

    it 'does not add more than MAX_SPANS' => sub {
      $tx->sampled(1);
      for (1 .. Sentry::Tracing::Transaction->MAX_SPANS + 1) {
        my $span = Sentry::Tracing::Span->new;
        $tx->add_span($span);
      }

      is scalar $tx->spans->@*, Sentry::Tracing::Transaction->MAX_SPANS;
    };
  };
};

runtests;
