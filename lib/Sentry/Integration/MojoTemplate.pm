package Sentry::Integration::MojoTemplate;

use Mojo::Base 'Sentry::Integration::Base', -signatures;
use Sentry::Util 'around';
use Try::Tiny;

has breadcrumbs        => 1;
has tracing            => 1;
has fix_stacktrace     => 1;
has template_namespace => 'Mojo::Template::Sandbox';

sub setup_once ($self, $add_global_event_processor, $get_current_hub) {
  if ($self->fix_stacktrace) {
    my $namespace = $self->template_namespace;
    $add_global_event_processor->(
      sub ($event, $hint) {
        return $event unless $event && exists $event->{exception}{values};
        for my $error ($event->{exception}{values}->@*) {
          _fix_template_stack_frames($namespace, $error->{stacktrace});
        }
        return $event;
      }
    );
  }

  around(
    'Mojo::Template',
    process => sub ($orig, $mojo_template, @args) {
      my $hub         = $get_current_hub->();
      my $parent_span = $self->tracing && $hub->get_current_scope->get_span;

      $hub->add_breadcrumb({
        type     => 'default',
        category => 'mojo.template',
        message  => "Rendering "
          . ($mojo_template->compiled ? 'cached ' : '')
          . $mojo_template->name,
      })
        if $self->breadcrumbs;

      my $span;
      if ($parent_span) {
        $span = $parent_span->start_child({
          op          => 'mojo.template',
          description => $mojo_template->name,
          data => { compiled => $mojo_template->compiled ? 'yes' : 'no', },
        });
      }

      my $output = $orig->($mojo_template, @args);
      $span->finish() if $span;
      return $output;
    }
  );
}

sub _fix_template_stack_frames($namespace, $stacktrace) {
  for my $frame ($stacktrace->frames->@*) {
    # Frames coming from Mojo templates will have their module set to
    # $namespace which is not very useful since it will be the same for all
    # templates. Additionally, if using Mojolicious::Plugin::EPRenderer, the
    # namespace will contain a hash value, which means it will mess up issue
    # grouping.
    # Remove module and subroutine from the frame so that Sentry falls back
    # to using the filename in the UI and for grouping.
    if ( $frame->module
      && $frame->module =~ /^${namespace}(::.*)?$/
      && $frame->filename) {
      $frame->module('');
      $frame->subroutine('');
    } elsif ($frame->subroutine) {
      # Remove namespace from subroutine name
      $frame->subroutine($frame->subroutine =~ s/^${namespace}:://r);
    }
  }
}

1;
