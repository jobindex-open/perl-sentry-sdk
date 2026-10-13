package Sentry::Integration;
use Mojo::Base -base, -signatures;

use Sentry::Hub;
use Sentry::Hub::Scope;
use Sentry::Integration::DBI;
use Sentry::Integration::DieHandler;
use Sentry::Integration::MojoUserAgent;
use Sentry::Integration::MojoTemplate;
use Sentry::Integration::LwpUserAgent;

sub _global_integrations {
  return qw(
    Sentry::Integration::DieHandler
    Sentry::Integration::DBI
    Sentry::Integration::MojoUserAgent
    Sentry::Integration::MojoTemplate
    Sentry::Integration::LwpUserAgent
  );
}

my %installed_integrations;

sub setup ($package, $custom_integrations = [], $with_defaults = 1) {
  my @all_integrations;
  if ($with_defaults) {
    my %already_added = map { ref $_ => 1 } @$custom_integrations;
    push @all_integrations, $_->new for grep { !$already_added{$_} } _global_integrations();
  }
  push @all_integrations, $custom_integrations->@*;
  foreach my $integration (grep { !$_->initialized } @all_integrations) {
    my $class = ref $integration;
    unless ($installed_integrations{$class}) {
      $integration->setup_once(
        Sentry::Hub::Scope->can('add_global_event_processor'),
        Sentry::Hub->can('get_current_hub'));
      $installed_integrations{$class} = 1;
    }

    $integration->initialized(1);
  }
  return @all_integrations;
}

1;
