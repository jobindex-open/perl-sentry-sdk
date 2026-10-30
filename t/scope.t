use Mojo::Base -strict, -signatures;

use Mojo::File;
# curfile missing in Mojolicious@^8. The dependency shall not be updated for
# the time being. For this reason `curfile` is duplicated for now.
# use lib curfile->sibling('lib')->to_string;
# See https://github.com/mojolicious/mojo/blob/4093223cae00eb516e38f2226749d2963597cca3/lib/Mojo/File.pm#L36
use lib Mojo::File->new(Cwd::realpath((caller)[1]))->sibling('lib')->to_string;

use Mojo::Util 'dumper';
use Sentry::Hub::Scope;
use Sentry::Severity;
use Sentry::Tracing::Span;
use Sentry::Tracing::Transaction;
use Test::Exception;
use Test::Spec;

describe 'Sentry::Hub::Scope' => sub {
  my $scope;
  my $span;
  my $tx;

  before each => sub {
    # Reset global event processors
    splice Sentry::Hub::Scope::get_global_event_processors()->@*, 0,
      Sentry::Hub::Scope::get_global_event_processors()->@*;

    $tx   = Sentry::Tracing::Transaction->new();
    $span = Sentry::Tracing::Span->new(
      { transaction => $tx, request => { url => 'http://example.com' } });
    $scope = Sentry::Hub::Scope->new({ span => $span });
  };

  describe 'clone()' => sub {
    it
      'shares the active span and records children on the original transaction'
      => sub {
        $tx->sampled(1);

        my $clone = $scope->clone;
        isnt $clone, $scope;
        isa_ok $clone, 'Sentry::Hub::Scope';
        is $clone->get_span,              $span;
        is $clone->get_span->transaction, $tx;

        my $child = $clone->get_span->start_child;
        is_deeply $tx->spans, [$child];
        is $child->transaction, $tx;

        $clone->set_span($child);
        is $scope->get_span, $span;
      };

    it 'shares an active transaction directly' => sub {
      $scope->set_span($tx);

      my $clone = $scope->clone;
      is $clone->get_span, $tx;
    };

    it 'shallow copies contexts' => sub {
      my $nested = { value => 'original' };
      $scope->contexts({ existing => $nested });

      my $clone = $scope->clone;
      isnt $clone->contexts, $scope->contexts;
      is_deeply $clone->contexts, $scope->contexts;
      is $clone->contexts->{existing}, $nested;

      $clone->contexts->{added} = 'clone only';
      ok !exists $scope->contexts->{added};
      delete $clone->contexts->{existing};
      is $scope->contexts->{existing}, $nested;
    };

    it 'shallow copies extra' => sub {
      my $nested = { value => 'original' };
      $scope->extra({ existing => $nested });

      my $clone = $scope->clone;
      isnt $clone->extra, $scope->extra;
      is_deeply $clone->extra, $scope->extra;
      is $clone->extra->{existing}, $nested;

      $clone->extra->{added} = 'clone only';
      ok !exists $scope->extra->{added};
      delete $clone->extra->{existing};
      is $scope->extra->{existing}, $nested;
    };

    it 'shallow copies tags' => sub {
      my $nested = { value => 'original' };
      $scope->tags({ existing => $nested });

      my $clone = $scope->clone;
      isnt $clone->tags, $scope->tags;
      is_deeply $clone->tags, $scope->tags;
      is $clone->tags->{existing}, $nested;

      $clone->tags->{added} = 'clone only';
      ok !exists $scope->tags->{added};
      delete $clone->tags->{existing};
      is $scope->tags->{existing}, $nested;
    };

    it 'shallow copies breadcrumbs' => sub {
      my $entry = { message => 'original' };
      $scope->breadcrumbs([$entry]);

      my $clone = $scope->clone;
      isnt $clone->breadcrumbs, $scope->breadcrumbs;
      is_deeply $clone->breadcrumbs, [$entry];
      is $clone->breadcrumbs->[0], $entry;

      push $clone->breadcrumbs->@*, $entry;
      is_deeply $scope->breadcrumbs, [$entry];
    };

    it 'shallow copies event processors' => sub {
      my $entry = sub ($event, $hint = undef) { return $event };
      $scope->event_processors([$entry]);

      my $clone = $scope->clone;
      isnt $clone->event_processors, $scope->event_processors;
      is_deeply $clone->event_processors, [$entry];
      is $clone->event_processors->[0], $entry;

      push $clone->event_processors->@*, $entry;
      is_deeply $scope->event_processors, [$entry];
    };

    it 'shallow copies error event processors' => sub {
      my $entry = sub ($event, $hint = undef) { return $event };
      $scope->error_event_processors([$entry]);

      my $clone = $scope->clone;
      isnt $clone->error_event_processors, $scope->error_event_processors;
      is_deeply $clone->error_event_processors, [$entry];
      is $clone->error_event_processors->[0], $entry;

      push $clone->error_event_processors->@*, $entry;
      is_deeply $scope->error_event_processors, [$entry];
    };

    it 'shares user data until replaced' => sub {
      $scope->set_user({ id => 'original' });

      my $clone = $scope->clone;
      is $clone->user, $scope->user;

      $clone->set_user({ id => 'clone' });
      is_deeply $scope->user, { id => 'original' };
    };

    it 'shares fingerprints until replaced' => sub {
      $scope->set_fingerprint(['original']);

      my $clone = $scope->clone;
      is $clone->fingerprint, $scope->fingerprint;

      $clone->set_fingerprint(['clone']);
      is_deeply $scope->fingerprint, ['original'];
    };

    it 'copies the logger independently' => sub {
      $scope->set_logger('original');

      my $clone = $scope->clone;
      is $clone->logger, 'original';

      $clone->set_logger('clone');
      is $scope->logger, 'original';
    };

    it 'copies the level independently' => sub {
      $scope->set_level(Sentry::Severity->Warning);

      my $clone = $scope->clone;
      is $clone->level, Sentry::Severity->Warning;

      $clone->set_level(Sentry::Severity->Fatal);
      is $scope->level, Sentry::Severity->Warning;
    };

    it 'copies the transaction name independently' => sub {
      $scope->set_transaction_name('original transaction');

      my $clone = $scope->clone;
      is $clone->transaction_name, 'original transaction';

      $clone->set_transaction_name('clone transaction');
      is $scope->transaction_name, 'original transaction';
    };

    it 'handles an empty scope' => sub {
      $scope = Sentry::Hub::Scope->new;

      my $clone = $scope->clone;
      is_deeply $clone, $scope;
      is $clone->get_span, undef;
    };
  };

  describe 'apply_to_event()' => sub {

    it 'sets the request payload', sub {
      my $event = $scope->apply_to_event({});

      is_deeply $event->{request}, { url => 'http://example.com' };
    };

    describe 'level' => sub {
      it 'has no default level' => sub {
        my $event = $scope->apply_to_event({});

        is $event->{level}, undef;
      };

      it 'overrides the event level' => sub {
        $scope->set_level(Sentry::Severity->Warning);
        my $event
          = $scope->apply_to_event({ level => Sentry::Severity->Fatal });

        is $event->{level}, Sentry::Severity->Warning;
      };
    };
  };

  describe 'global event processors' => sub {
    it 'defaults to an empty array ref' => sub {
      is_deeply Sentry::Hub::Scope::get_global_event_processors, [];
    };

    it 'adds an event processor' => sub {
      my $processor = sub ($event, $hint = undef) {
        return undef;
      };
      Sentry::Hub::Scope::add_global_event_processor($processor);

      is_deeply Sentry::Hub::Scope::get_global_event_processors, [$processor];
    };

    it 'uses the global event processor' => sub {
      my $processor = sub ($event, $hint = undef) {
        $event->{foo} = 'bar';
        return $event;
      };
      Sentry::Hub::Scope::add_global_event_processor($processor);

      my $event
        = $scope->apply_to_event({ level => Sentry::Severity->Fatal });

      is $event->{foo}, 'bar';
    };
  };

  describe 'set_extras' => sub {
    it 'set_extras should not crash' => sub {
      lives_ok { Sentry::Hub::Scope->new->set_extras({ foo => 'bar' }) };
    };
  };

  describe 'add_breadcrumb' => sub {
    it 'limits breadcrumb items' => sub {
      local $ENV{SENTRY_MAX_BREADCRUMBS} = 2;

      $scope->add_breadcrumb({ message => 'foo' });
      $scope->add_breadcrumb({ message => 'bar' });
      $scope->add_breadcrumb({ message => 'baz' });

      is scalar $scope->breadcrumbs->@*,      2;
      is $scope->breadcrumbs->[0]->{message}, 'bar';
      is $scope->breadcrumbs->[1]->{message}, 'baz';
    };
  };
};

runtests;
