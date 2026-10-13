use Mojo::Base -strict, -signatures;

use Mojo::File;
# curfile missing in Mojolicious@^8. The dependency shall not be updated for
# the time being. For this reason `curfile` is duplicated for now.
# use lib curfile->sibling('lib')->to_string;
# See https://github.com/mojolicious/mojo/blob/4093223cae00eb516e38f2226749d2963597cca3/lib/Mojo/File.pm#L36
use lib Mojo::File->new(Cwd::realpath((caller)[1]))->sibling('lib')->to_string;

use Sentry::Hub::Scope;
use Sentry::Integration;
use Test::Spec;

{
  package Local::CountingIntegration;
  use Mojo::Base 'Sentry::Integration::Base', -signatures;

  our $setup_count = 0;

  sub setup_once ($self, $add_global_event_processor, $get_current_hub) {
    $setup_count++;
  }
}

describe 'Sentry::Integration' => sub {
  describe 'setup()' => sub {
    it 'sets up each integration class only once per process' => sub {
      for (1 .. 3) {
        my @integrations
          = Sentry::Integration->setup([Local::CountingIntegration->new], 0);
        ok $integrations[0]->initialized;
      }

      is $Local::CountingIntegration::setup_count, 1;
    };

    it 'does not stack default integrations on repeated setup' => sub {
      Sentry::Integration->setup([], 1);

      my $processor_count
        = scalar Sentry::Hub::Scope::get_global_event_processors()->@*;
      my $dbi_do = \&DBI::db::do;

      Sentry::Integration->setup([], 1) for 1 .. 5;

      is scalar Sentry::Hub::Scope::get_global_event_processors()->@*,
        $processor_count;
      is \&DBI::db::do, $dbi_do;
    };
  };
};

runtests;
