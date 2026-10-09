package Sentry::Tracing::Transaction;
use Mojo::Base 'Sentry::Tracing::Span', -signatures;

# https://develop.sentry.dev/sdk/unified-api/tracing

use Sentry::Logger 'logger';

use Mojo::Util 'dumper';

has _hub        => undef, weak => 1;
has sampled     => undef;
has context     => undef;
has name        => '<unlabeled transaction>';
has spans       => sub { [] };
has transaction => sub ($self) {$self}, weak => 1;

use constant MAX_SPANS => 1000;

sub finish ($self) {
  $self->SUPER::finish();

  return unless $self->sampled;

  my @finished_spans = grep { $_->timestamp } $self->spans->@*;

  my %transaction = (
    contexts        => { trace => $self->get_trace_context(), },
    spans           => \@finished_spans,
    start_timestamp => $self->start_timestamp,
    tags            => $self->tags,
    timestamp       => $self->timestamp,
    transaction     => $self->name,
    request         => $self->request,
    type            => 'transaction',
  );

  $self->_hub->capture_event(\%transaction);
}

sub set_name ($self, $name) {
  $self->name($name);
}

sub add_span ($self, $span) {
  return unless $self->sampled;
  if (scalar $self->spans->@* >= MAX_SPANS) {
    logger->log(
      'Discarding span because maximum span count has been reached',
      'Tracing'
    );
  } else {
    push $self->spans->@*, $span;
  }
}

1;
