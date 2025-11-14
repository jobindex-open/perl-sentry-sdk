use Mojo::Base -strict, -signatures;

use Mojo::File;
# curfile missing in Mojolicious@^8. The dependency shall not be updated for
# the time being. For this reason `curfile` is duplicated for now.
# use lib curfile->sibling('lib')->to_string;
# See https://github.com/mojolicious/mojo/blob/4093223cae00eb516e38f2226749d2963597cca3/lib/Mojo/File.pm#L36
use lib Mojo::File->new(Cwd::realpath((caller)[1]))->sibling('lib')->to_string;

use HTTP::Status qw(:constants);
use Mock::Mojo::UserAgent;
use Mojo::JSON qw(decode_json);
use Mojo::Util 'dumper';
use Mojolicious::Plugin::SentrySDK;
use Sentry::SDK;
use Test::Mojo;
use Test::Spec;

{

  package MyApp;
  use Mojo::Base 'Mojolicious', -signatures;

  use Mojo::UserAgent;

  sub startup ($self) {
    $self->plugin(
      'SentrySDK',
      {
        dsn =>
          'http://ff21cbe6ddaf4314833eabd2075e38e3@example.com/foo/bar/2',
        traces_sample_rate => 1,
      }
    );

    $self->routes->get('/')->to('foo#index');
    $self->routes->get('/adds-breadcrumb')->to('foo#adds_breadcrumb');
    $self->routes->post('/post-json')->to('foo#post_json');
    $self->routes->post('/post-form')->to('foo#post_form');
    $self->routes->post('/post-large')->to('foo#post_large');
    my $route = $self->routes->get('/dies')->to(controller => 'foo');
    $route->get('')->to(action => 'dies');
    $route->get('/nested/:foo')->to(action => 'dies');
  }

  package MyApp::Controller::Foo;
  use Mojo::Base 'Mojolicious::Controller', -signatures;

  sub index ($self) {
    use Try::Tiny;
    Sentry::SDK->add_breadcrumb({ category => 'foo', message => 'hello' });
    Sentry::SDK->capture_message('hello');

    $self->render(text => 'Hello World!');
  }

  sub adds_breadcrumb ($self) {
    Sentry::SDK->add_breadcrumb({ category => 'foo', message => 'hello' });
    Sentry::SDK->capture_message('hello');
    $self->render(text => 'breadcrumb added!');
  }

  sub post_json ($self) {
    my $json = $self->req->json;
    $self->render(json => { received => $json });
  }

  sub post_form ($self) {
    my $params = $self->req->body_params->to_hash;
    $self->render(json => { received => $params });
  }

  sub post_large ($self) {
    $self->render(json => { received => 'ok' });
  }

  sub dies { die 'boom' }
}

describe 'Mojolicious::Plugin::SentrySDK' => sub {
  my $t;
  my $http;

  before each => sub {
    $http = Mock::Mojo::UserAgent->new;

    $t = Test::Mojo->new('MyApp');

    $t->app->hook(
      before_server_start => sub {
        my $client = Sentry::Hub->get_current_hub->client;
        $client->_transport->_http($http);
      }
    );
  };

  it 'does not crash the application' => sub {
    $t->get_ok('/')->status_is(HTTP_OK)->content_is('Hello World!');
  };

  it 'captures exceptions' => sub {
    $t->get_ok('/dies')->status_is(HTTP_INTERNAL_SERVER_ERROR);

    # Notification; Transaction
    is $http->requests->@*, 2;
    isa_ok($http->requests->[0]{body}, 'HASH');
    is ref($http->requests->[1]{body}), '';

    ok exists $http->requests->[0]{body}{exception};

    is $http->requests->[0]{body}{level}, Sentry::Severity->Error;
  };

  it 'registers breadcrumbs' => sub {
    # Sentry-Requests are ignored in the MojoUserAgent integration
    my %do_not_track = ('x-sentry-auth' => 1);
    %do_not_track = ();
    $t->get_ok('/adds-breadcrumb' => \%do_not_track)->status_is(HTTP_OK)
      ->content_is('breadcrumb added!');

    # Notification; Transaction
    is $http->requests->@*, 2;

    my %event = $http->requests->[0]{body}->%*;

    is $event{message} => 'hello';
    is $event{level}   => 'info';

    # is $event{breadcrumbs}->@*           => 1;
    is $event{breadcrumbs}[-1]{category} => 'foo';
    is $event{breadcrumbs}[-1]{message}  => 'hello';
  };

  it 'nested route has full transaction name' => sub {
    $t->get_ok('/dies/nested/1')->status_is(HTTP_INTERNAL_SERVER_ERROR);
    is $http->requests->@*, 2;

    my %event = $http->requests->[0]{body}->%*;

    is $event{transaction} => '/dies/nested/:foo';

  };

  describe 'max_request_body_size configuration' => sub {
    it 'never - does not capture request bodies' => sub {
      my $http_local = Mock::Mojo::UserAgent->new;
      my $t_local = Test::Mojo->new('MyApp');

      $t_local->app->plugin(
        'SentrySDK',
        {
          dsn => 'http://key@example.com/foo/bar/2',
          traces_sample_rate => 1,
          max_request_body_size => 'never',
        }
      );

      $t_local->app->hook(
        before_server_start => sub {
          my $client = Sentry::Hub->get_current_hub->client;
          $client->_transport->_http($http_local);
        }
      );

      $t_local->post_ok('/post-json' => json => { key => 'value' })
        ->status_is(HTTP_OK);

      my @lines = split /\n/, $http_local->requests->[0]{body};
      my $transaction = decode_json($lines[2]);
      my $request = $transaction->{request};

      ok !exists $request->{data}, 'no data captured with never';
    };

    it 'small - captures bodies up to 4KB' => sub {
      my $http_local = Mock::Mojo::UserAgent->new;
      my $t_local = Test::Mojo->new('MyApp');

      $t_local->app->plugin(
        'SentrySDK',
        {
          dsn => 'http://key@example.com/foo/bar/2',
          traces_sample_rate => 1,
          max_request_body_size => 'small',
        }
      );

      $t_local->app->hook(
        before_server_start => sub {
          my $client = Sentry::Hub->get_current_hub->client;
          $client->_transport->_http($http_local);
        }
      );

      # Small body should be captured
      $t_local->post_ok('/post-json' => json => { key => 'value' })
        ->status_is(HTTP_OK);

      my @lines = split /\n/, $http_local->requests->[0]{body};
      my $transaction = decode_json($lines[2]);
      is $transaction->{request}{data}{key}, 'value', 'small body captured';

      # Body > 4KB should be replaced
      $http_local->requests([]);
      my $large_string = 'x' x 5000;
      $t_local->post_ok('/post-json' => json => { large => $large_string })
        ->status_is(HTTP_OK);

      @lines = split /\n/, $http_local->requests->[0]{body};
      $transaction = decode_json($lines[2]);
      is $transaction->{request}{data}, '[too large]', 'body > 4KB replaced';
    };

    it 'medium (default) - captures bodies up to 10KB' => sub {
      my $http_local = Mock::Mojo::UserAgent->new;
      my $t_local = Test::Mojo->new('MyApp');

      $t_local->app->plugin(
        'SentrySDK',
        {
          dsn => 'http://key@example.com/foo/bar/2',
          traces_sample_rate => 1,
          # max_request_body_size defaults to 'medium'
        }
      );

      $t_local->app->hook(
        before_server_start => sub {
          my $client = Sentry::Hub->get_current_hub->client;
          $client->_transport->_http($http_local);
        }
      );

      # 5KB body should be captured
      my $medium_string = 'x' x 5000;
      $t_local->post_ok('/post-json' => json => { data => $medium_string })
        ->status_is(HTTP_OK);

      my @lines = split /\n/, $http_local->requests->[0]{body};
      my $transaction = decode_json($lines[2]);
      is length($transaction->{request}{data}{data}), 5000, 'medium body captured';

      # Body > 10KB should be replaced
      $http_local->requests([]);
      my $large_string = 'x' x 11000;
      $t_local->post_ok('/post-json' => json => { large => $large_string })
        ->status_is(HTTP_OK);

      @lines = split /\n/, $http_local->requests->[0]{body};
      $transaction = decode_json($lines[2]);
      is $transaction->{request}{data}, '[too large]', 'body > 10KB replaced';
    };

    it 'always - captures bodies regardless of size' => sub {
      my $http_local = Mock::Mojo::UserAgent->new;
      my $t_local = Test::Mojo->new('MyApp');

      $t_local->app->plugin(
        'SentrySDK',
        {
          dsn => 'http://key@example.com/foo/bar/2',
          traces_sample_rate => 1,
          max_request_body_size => 'always',
        }
      );

      $t_local->app->hook(
        before_server_start => sub {
          my $client = Sentry::Hub->get_current_hub->client;
          $client->_transport->_http($http_local);
        }
      );

      # Very large body should still be captured
      my $very_large_string = 'x' x 20000;
      $t_local->post_ok('/post-json' => json => { huge => $very_large_string })
        ->status_is(HTTP_OK);

      my @lines = split /\n/, $http_local->requests->[0]{body};
      my $transaction = decode_json($lines[2]);
      is length($transaction->{request}{data}{huge}), 20000, 'large body captured with always';
    };
  };

  describe 'request data handling' => sub {
    it 'captures small JSON request data' => sub {
      $t->post_ok(
        '/post-json' => json => { username => 'test', password => 'secret' }
      )->status_is(HTTP_OK);

      # Transaction
      is $http->requests->@*, 1;

      # Parse envelope format (newline-separated JSON)
      my @lines = split /\n/, $http->requests->[0]{body};
      my $transaction = decode_json($lines[2]);  # Body is the third line
      my $request = $transaction->{request};

      ok exists $request->{data}, 'request data exists';
      is $request->{data}{username} => 'test';
      is $request->{data}{password} => 'secret';
    };

    it 'captures small form data' => sub {
      $t->post_ok(
        '/post-form' => form => { username => 'test', email => 'test@example.com' }
      )->status_is(HTTP_OK);

      # Transaction
      is $http->requests->@*, 1;

      # Parse envelope format
      my @lines = split /\n/, $http->requests->[0]{body};
      my $transaction = decode_json($lines[2]);
      my $request = $transaction->{request};

      ok exists $request->{data}, 'request data exists';
      is $request->{data}{username} => 'test';
      is $request->{data}{email}    => 'test@example.com';
    };

    it 'does not truncate small JSON with large strings if body under 10KB' => sub {
      # Even with 2KB strings, the total JSON body is < 10KB
      my $large_string = 'x' x 2000;  # 2KB string
      $t->post_ok(
        '/post-json' => json => {
          small => 'value',
          large => $large_string,
          nested => { deep => $large_string }
        }
      )->status_is(HTTP_OK);

      # Transaction
      is $http->requests->@*, 1;

      # Parse envelope format
      my @lines = split /\n/, $http->requests->[0]{body};
      my $transaction = decode_json($lines[2]);
      my $request = $transaction->{request};

      ok exists $request->{data}, 'request data exists';
      is $request->{data}{small} => 'value', 'small field preserved';
      # Body is < 10KB so data is returned as-is without truncation
      is length($request->{data}{large}), 2000, 'large field not truncated';
      is length($request->{data}{nested}{deep}), 2000, 'nested field not truncated';
    };

    it 'replaces large JSON bodies with placeholder' => sub {
      # Create JSON that exceeds 10KB
      my $large_string = 'y' x 6000;  # 6KB string
      $t->post_ok(
        '/post-json' => json => {
          field1 => $large_string,
          field2 => $large_string,
          nested => { deep => $large_string }
        }
      )->status_is(HTTP_OK);

      # Transaction
      is $http->requests->@*, 1;

      # Parse envelope format
      my @lines = split /\n/, $http->requests->[0]{body};
      my $transaction = decode_json($lines[2]);
      my $request = $transaction->{request};

      ok exists $request->{data}, 'request data exists';
      is $request->{data}, '[too large]', 'large body replaced with placeholder';
    };

    it 'replaces file uploads with placeholder but keeps text fields' => sub {
      # Note: Test::Mojo's multipart form handling
      $t->post_ok(
        '/post-large' => form => {
          username => 'testuser',
          email    => 'test@example.com',
          file     => { content => 'file data' }
        }
      )->status_is(HTTP_OK);

      # Transaction
      is $http->requests->@*, 1;

      # Parse envelope format
      my @lines = split /\n/, $http->requests->[0]{body};
      my $transaction = decode_json($lines[2]);
      my $request = $transaction->{request};

      ok exists $request->{data}, 'request data exists';
      is $request->{data}{username}, 'testuser', 'text field preserved';
      is $request->{data}{email}, 'test@example.com', 'email field preserved';
      is $request->{data}{file}, '[file upload]', 'file upload replaced with placeholder';
    };

    it 'does not send raw request bodies' => sub {
      $t->post_ok('/post-large' => { 'Content-Type' => 'text/plain' } => 'plain text body')
        ->status_is(HTTP_OK);

      # Transaction
      is $http->requests->@*, 1;

      # Parse envelope format
      my @lines = split /\n/, $http->requests->[0]{body};
      my $transaction = decode_json($lines[2]);
      my $request = $transaction->{request};

      ok !exists $request->{data}, 'raw body not included';
    };

    it 'does not include data for GET requests' => sub {
      $t->get_ok('/')->status_is(HTTP_OK);

      # Notification; Transaction
      is $http->requests->@*, 2;

      # Parse envelope format for transaction (second request)
      my @lines = split /\n/, $http->requests->[1]{body};
      my $transaction = decode_json($lines[2]);
      my $request = $transaction->{request};

      ok !exists $request->{data}, 'no request data for GET';
    };

    it 'handles invalid JSON gracefully' => sub {
      # Send invalid JSON with application/json content type
      $t->post_ok(
        '/post-json' => { 'Content-Type' => 'application/json' } =>
          '{"invalid": json}'
      )->status_is(HTTP_OK);

      # Transaction should still be sent
      is $http->requests->@*, 1;

      # Parse envelope format
      my @lines = split /\n/, $http->requests->[0]{body};
      my $transaction = decode_json($lines[2]);
      my $request = $transaction->{request};

      # When JSON parsing fails, no data should be sent
      ok !exists $request->{data}, 'no data for invalid JSON';
    };
  };
};

runtests;
