package Mock::Sentry::Integration::MockIntegration;
use Mojo::Base 'Sentry::Integration::Base', -signatures;

sub setup_once ($self, $add_global_event_processor, $get_current_hub) {}

1;
