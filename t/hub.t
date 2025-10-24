use Mojo::Base -strict, -signatures;

use Mojo::File;
# curfile missing in Mojolicious@^8. The dependency shall not be updated for
# the time being. For this reason `curfile` is duplicated for now.
# use lib curfile->sibling('lib')->to_string;
# See https://github.com/mojolicious/mojo/blob/4093223cae00eb516e38f2226749d2963597cca3/lib/Mojo/File.pm#L36
use lib Mojo::File->new(Cwd::realpath((caller)[1]))->sibling('lib')->to_string;

use Sentry::Hub;
use Test::Spec;
use Try::Tiny;

describe 'Sentry::Hub' => sub {
  my $hub;

  before each => sub {
    $hub = Sentry::Hub->get_current_hub();
    $hub->reset();
  };

  describe 'with_scope()' => sub {
    it 'leaves current scope unchanged' => sub {
      my $current_scope = $hub->get_current_scope;
      $current_scope->set_tag('key', 'foo');
      my $expected_scope = $current_scope->clone;
      $hub->with_scope(sub ($new_scope) {
        $new_scope->set_tag('key', 'bar');
      });
      is_deeply($hub->get_current_scope, $expected_scope, 'current scope is unchanged');
    };
    it 'throws error if callback throws error' => sub {
      my $e;
      try {
        $hub->with_scope(sub {
          die "foo";
        });
      } catch {
        $e = $_;
      };
      like($e, qr/foo/, "with_scope threw error");
    };
    it 'leaves current scope unchanged if callback dies' => sub {
      my $current_scope = $hub->get_current_scope;
      $current_scope->set_tag('key', 'foo');
      my $expected_scope = $current_scope->clone;
      try {
        $hub->with_scope(sub ($new_scope) {
          $new_scope->set_tag('key', 'bar');
          die "baah";
        });
      };
      is_deeply($hub->get_current_scope, $expected_scope, 'current scope is unchanged');
    };
  };
};

runtests;
