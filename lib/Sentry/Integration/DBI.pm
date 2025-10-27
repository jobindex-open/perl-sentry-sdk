package Sentry::Integration::DBI;
use Mojo::Base 'Sentry::Integration::Base', -signatures;

has breadcrumbs => 1;
has tracing     => 1;

# DBI is special. Classes are generated on-the-fly.
sub around ($package, $method, $cb) {
  ## no critic (TestingAndDebugging::ProhibitNoStrict, TestingAndDebugging::ProhibitNoWarnings, TestingAndDebugging::ProhibitProlongedStrictureOverride)
  no strict 'refs';
  no warnings 'redefine';

  my $symbol = join('::', $package, $method);

  my $orig = \&{$symbol};
  *{$symbol} = sub { $cb->($orig, @_) };

  return;
}

sub setup_once ($self, $add_global_event_processor, $get_current_hub) {
  return if !$self->breadcrumbs && !$self->tracing;

  around(
    'DBI::db',
    do => sub ($orig, $dbh, $statement, @args) {
      my $hub = $get_current_hub->();

      my $span;
      my %span_data = $self->tracing || $self->breadcrumbs
        ? _get_query_data(\@args)
        : ();

      if ($self->tracing && (my $parent_span = $hub->get_scope()->get_span)) {
        $span = $parent_span->start_child({
          op          => 'db.sql.execute',
          description => $statement,
          data        => { %span_data, _get_db_data($dbh) },
        });
      }

      if ($self->breadcrumbs) {
        _record_breadcrumb($hub, $statement, \%span_data);
      }

      my $value = $orig->($dbh, $statement, @args);

      if (defined $span && $self->tracing) {
        $span->finish();
      }

      return $value;
    }
  );

  around(
    'DBI::st',
    execute => sub ($orig, $sth, @args) {
      my $statement = $sth->{Statement};

      my $hub = $get_current_hub->();

      my $span;
      my %span_data = $self->tracing || $self->breadcrumbs
        ? _get_query_data(\@args)
        : ();

      if ($self->tracing && (my $parent_span = $hub->get_scope()->get_span)) {
        $span = $parent_span->start_child({
          op               => 'db.sql.execute',
          description      => $statement,
          data             => { %span_data, _get_db_data($sth->{Database}) },
        });
      }

      if ($self->breadcrumbs) {
        _record_breadcrumb($hub, $statement, \%span_data);
      }

      my $value = $orig->($sth, @args);

      if (defined $span && $self->tracing) {
        $span->finish();
      }

      return $value;
    }
  );
}

sub _record_breadcrumb($hub, $statement, $span_data) {
  $hub->add_breadcrumb({
      type     => 'query',
      category => 'query',
      message  => $statement,
      data     => $span_data,
    });
}

sub _get_query_data($args) {
  my %data;

  if ($args && @$args) {
    $data{args} = $args;
  }

  return %data;
}

sub _get_db_data($dbh) {
  my %data;

  my $db_name_info_type = 17; # SQL_DBMS_NAME
  my $db_name = $dbh->get_info($db_name_info_type);
  $data{'db.system.name'} = lc($db_name) if $db_name;

  return %data;
}

1;
