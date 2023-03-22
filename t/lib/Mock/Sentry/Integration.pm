package Mock::Sentry::Integration;
use Mojo::Base -base, -signatures;

has default_integrations => 1;
has integrations => sub { [] };

sub setup($self, $integrations, $with_defaults) {
  $self->default_integrations($with_defaults);
  push $self->integrations->@*, @$integrations;
  return $self->integrations->@*;
}

1;
