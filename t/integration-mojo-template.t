use Test::Spec;

use Cwd;
use Mojo::Base -strict, -signatures;
use Mojo::File;
use Mojo::Template;
use Sentry::Hub;
use Sentry::Hub::Scope;
use Sentry::Integration::MojoTemplate;
use Sentry::Stacktrace;
use Sentry::Tracing::Span;
use Sentry::Util qw(restore_original);

# curfile missing in Mojolicious@^8. The dependency shall not be updated for
# the time being. For this reason `curfile` is duplicated for now.
# use lib curfile->sibling('lib')->to_string;
# See https://github.com/mojolicious/mojo/blob/4093223cae00eb516e38f2226749d2963597cca3/lib/Mojo/File.pm#L36
use lib Mojo::File->new(Cwd::realpath((caller)[1]))->sibling('lib')->to_string;

describe 'Sentry::Integration::MojoTemplate' => sub {
  my $integration;
  my $hub;
  my $scope;
  my $setup;

  before each => sub {
    $hub   = Sentry::Hub->new;
    $scope = $hub->get_current_scope;

    $setup = sub (%options) {
      $integration = Sentry::Integration::MojoTemplate->new(%options);
      $integration->setup_once($scope->can('add_global_event_processor'),
        sub {$hub});
    };
  };

  after each => sub {
    restore_original 'Mojo::Template', 'process';
    splice Sentry::Hub::Scope::get_global_event_processors()->@*, 0;
    $scope->clear_breadcrumbs;
  };

  it 'creates a span when rendering template' => sub {
    $setup->();
    my $span = Sentry::Tracing::Span->new();
    $scope->set_span($span);

    my $mt = Mojo::Template->new(name => 'tmpl foo');
    $mt->render('foo');

    is scalar $span->spans->@*, 1;
    my %tmpl_span = $span->spans->[0]->%*;
    is $tmpl_span{description}, 'tmpl foo';
    is $tmpl_span{op},          'mojo.template';
    is_deeply $tmpl_span{data}, { compiled => 'no' };
  };

  it 'creates a breadcrumb when rendering template' => sub {
    $setup->();
    my $span = Sentry::Tracing::Span->new();
    $scope->set_span($span);

    my $mt = Mojo::Template->new(name => 'tmpl foo');
    $mt->render('foo');

    is scalar $scope->breadcrumbs->@*, 1;
    my %breadcrumb = $scope->breadcrumbs->[-1]->%*;
    is $breadcrumb{type},     'default';
    is $breadcrumb{category}, 'mojo.template';
    is $breadcrumb{message},  'Rendering tmpl foo';

    # Render compiled template
    $mt->process('foo');

    is scalar $scope->breadcrumbs->@*, 2;
    %breadcrumb = $scope->breadcrumbs->[-1]->%*;
    is $breadcrumb{message},  'Rendering cached tmpl foo';
  };

  it 'fixes stacktrace by default' => sub {
    $setup->();
    my $scope = $hub->get_current_scope;
    my $span  = Sentry::Tracing::Span->new();
    $scope->set_span($span);

    my $mt = Mojo::Template->new(
      name      => 'tmpl foo',
      namespace => 'Mojo::Template::Sandbox::deadbeef'
    );
    my $output = $mt->render('<% die "boom"; %>');

    my $stacktrace
      = Sentry::Stacktrace->new(exception => $output, frame_filter => sub {1},);
    my $event = $scope->apply_to_event({
      exception => { values => [{ stacktrace => $stacktrace }] } });

    my $last_frame = $stacktrace->frames->[-1];
    is $last_frame->module,     '';
    is $last_frame->filename,   'tmpl foo';
    is $last_frame->subroutine, '';
  };

  it 'fixes stacktrace with custom namespace' => sub {
    $setup->(template_namespace => 'My::Custom::Namespace');
    my $scope = $hub->get_current_scope;
    my $span  = Sentry::Tracing::Span->new();
    $scope->set_span($span);

    my $mt = Mojo::Template->new(
      name      => 'tmpl foo',
      namespace => 'My::Custom::Namespace'
    );
    my $output = $mt->render('<% die "boom"; %>');

    my $stacktrace
      = Sentry::Stacktrace->new(exception => $output, frame_filter => sub {1},);
    my $event = $scope->apply_to_event({
      exception => { values => [{ stacktrace => $stacktrace }] } });

    my $last_frame = $stacktrace->frames->[-1];
    is $last_frame->module,     '';
    is $last_frame->filename,   'tmpl foo';
    is $last_frame->subroutine, '';
  };

  it 'does not fix stacktrace when fix_stacktrace is false' => sub {
    $setup->(fix_stacktrace => 0);
    my $scope = $hub->get_current_scope;
    my $span  = Sentry::Tracing::Span->new();
    $scope->set_span($span);

    my $mt = Mojo::Template->new(
      name      => 'tmpl foo',
      namespace => 'Mojo::Template::Sandbox::deadbeef'
    );
    my $output = $mt->render('<% die "boom"; %>');

    my $stacktrace
      = Sentry::Stacktrace->new(exception => $output, frame_filter => sub {1},);
    my $event = $scope->apply_to_event({
      exception => { values => [{ stacktrace => $stacktrace }] } });

    my $last_frame = $stacktrace->frames->[-1];
    is $last_frame->module,     'Mojo::Template::Sandbox::deadbeef';
    is $last_frame->filename,   'tmpl foo';
    is $last_frame->subroutine, 'Mojo::Template::Sandbox::deadbeef::__ANON__';
  };
};

runtests;
