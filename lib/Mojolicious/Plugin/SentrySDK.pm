package Mojolicious::Plugin::SentrySDK;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Mojolicious;
use List::Util qw(pairgrep);
use Sentry::Hub;
use Sentry::Logger 'logger';
use Sentry::SDK;
use Sentry::Util qw(stringify_ref);
use Try::Tiny;

# Request body size limits based on max_request_body_size setting
use constant {
  MAX_REQUEST_BODY_SMALL  => 4 * 1024,   # 4KB
  MAX_REQUEST_BODY_MEDIUM => 10 * 1024,  # 10KB
};

sub _get_max_body_size ($max_request_body_size) {
  return 0                         if $max_request_body_size eq 'never';
  return MAX_REQUEST_BODY_SMALL    if $max_request_body_size eq 'small';
  return MAX_REQUEST_BODY_MEDIUM   if $max_request_body_size eq 'medium';
  return undef                     if $max_request_body_size eq 'always';
  # Default to medium if invalid value
  logger->warn("Invalid max_request_body_size value '$max_request_body_size', defaulting to 'medium'");
  return MAX_REQUEST_BODY_MEDIUM;
}

sub _extract_request_data ($req, $max_body_size) {
  my $content_type = $req->headers->content_type // '';
  my $body_size = $req->body_size // 0;

  # Return undef for GET/HEAD requests or empty bodies
  return undef if $body_size == 0;
  return undef if $req->method =~ /^(GET|HEAD|OPTIONS)$/;

  # If max_body_size is 0 (never), don't send any request bodies
  return undef if defined $max_body_size && $max_body_size == 0;

  # Handle JSON content
  if ($content_type =~ m!^application/json!) {
    # Check the size before parsing so oversized bodies are never decoded
    return '[too large]' if defined $max_body_size && $body_size > $max_body_size;

    # If JSON parsing failed, don't send raw body
    return $req->json;
  }

  # Handle form data (application/x-www-form-urlencoded or multipart/form-data)
  if ($content_type =~ m!^(application/x-www-form-urlencoded|multipart/form-data)!) {
    # If body exceeds limit, replace with placeholder (unless always)
    return '[too large]' if defined $max_body_size && $body_size > $max_body_size;

    my $params = $req->body_params->to_hash;

    # For multipart/form-data, replace file upload values with placeholder
    if ($content_type =~ m!^multipart/form-data!) {
      for my $upload ($req->uploads->@*) {
        my $name = $upload->name;
        # Add or replace the file upload value with placeholder
        if (exists $params->{$name}) {
          if (ref $params->{$name} eq 'ARRAY') {
            # Multiple files with same name
            $params->{$name} = ['[file upload]'];
          } else {
            $params->{$name} = '[file upload]';
          }
        } else {
          # File upload not in body_params, add placeholder
          $params->{$name} = '[file upload]';
        }
      }
    }

    # Return form data with file uploads replaced
    return $params;
  }

  # Don't send raw request bodies for other content types
  return undef;
}

sub register ($self, $app, $conf) {
  # Get max_request_body_size setting, default to 'medium'
  my $max_request_body_size = $conf->{max_request_body_size} // 'medium';
  my $max_body_size = _get_max_body_size($max_request_body_size);
  $app->hook(
    before_server_start => sub ($server, $app) {
      Sentry::SDK->init($conf);
    }
  );

  $app->hook(
    around_action => sub ($next, $c, $action, $last) {
      return $next->() unless $last;

      my $req = $c->req;

      Sentry::Hub->get_current_hub()->with_scope(sub ($scope) {
        my %cookies = map { ($_->name, $_->value) } ($req->cookies // [])->@*;
        my $transaction_name = $c->match->endpoint->to_string || '/';
        $scope->set_transaction_name($transaction_name);

        # Extract and truncate request data
        my $request_data = _extract_request_data($req, $max_body_size);

        my $transaction = Sentry::SDK->start_transaction(
          {
            name    => $transaction_name,
            op      => 'http.server',
            request => {
              url          => $req->url->to_abs->to_string,
              cookies      => \%cookies,
              method       => $req->method,
              query_string => $req->url->query->to_hash,
              headers      => $req->headers->to_hash,
              env          => \%ENV,
              (defined $request_data ? (data => $request_data) : ()),
            },
          },
        );
        $scope->set_span($transaction);

        $scope->add_event_processor(
          sub ($event, $hint) {
            my $modules = $event->{modules} //= {};
            $modules->{Mojolicious} = $Mojolicious::VERSION;

            $event->{extra}->{session} = stringify_ref($c->session);
            my %stash = pairgrep { $a !~ /^mojo\./ } $c->stash->%*;
            $event->{extra}->{stash} = stringify_ref(\%stash);

            return $event;
          }
        );

        try {
          $next->();
        } catch {
          Sentry::SDK->capture_exception($_, { logger => 'mojo' });
          $c->reply->exception($_)
        } finally {
          my $status = $c->res->code;
          $transaction->set_http_status($status) if $status;
          $transaction->finish();
        };
      });
    }
  );

  $app->hook(
    before_render => sub ($c, $args) {
      return if $args->{'mojo.string'};
      my ($pkg, $file, $line) = caller 2;
      my %data = (
        $args->%{qw(template format handler layout extends inline json text mojo.rendered mojo.maybe)},
        data => $args->{data} && '[...]',
      );
      delete $data{$_} for grep { !$data{$_} } keys %data;
      Sentry::SDK->add_breadcrumb({
          category => 'mojo',
          level => Sentry::Severity->Info,
          message => "Rendering response in $pkg ($file:$line)",
          data => \%data,
        });
    }
  );
}

1;

=encoding utf8

=head1 NAME

Mojolicious::Plugin::SentrySDK - Sentry plugin for Mojolicious

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 OPTIONS

=head2 register

  my $config = $plugin->register(Mojolicious->new);
  my $config = $plugin->register(Mojolicious->new, \%options);

Register Sentry in L<Mojolicious> application.

=head1 SEE ALSO

L<Sentry::SDK>.

=cut
