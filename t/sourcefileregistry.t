use Mojo::Base -strict, -signatures;

use utf8;

use Mojo::File;
# curfile missing in Mojolicious@^8. The dependency shall not be updated for
# the time being. For this reason `curfile` is duplicated for now.
# use lib curfile->sibling('lib')->to_string;
# See https://github.com/mojolicious/mojo/blob/4093223cae00eb516e38f2226749d2963597cca3/lib/Mojo/File.pm#L36
use lib Mojo::File->new(Cwd::realpath((caller)[1]))->sibling('lib')->to_string;

use Mojo::Exception;
use Mojo::Home;
use Mojo::JSON;
use Sentry::Stacktrace;
use Sentry::Stacktrace::Frame;
use Mock::Sentry::SourceFileRegistry;
use Test::Exception;
use Test::Spec;

{

  package My::Exception;
  use Mojo::Base -base;
}

describe 'Sentry::SourceFileRegistry' => sub {
  it 'decodes source file as utf8' => sub {
    my $reg = Sentry::SourceFileRegistry->new;
    my $context = $reg->get_context_lines('t/data/source-file-utf8.pl', 2);
    is $context->{context_line}, 'print "this file contains valid utf8 content: 🦄\n";'
  };

  it 'handles non-utf-8 source files' => sub {
    my $reg = Sentry::SourceFileRegistry->new;
    my $context = $reg->get_context_lines('t/data/source-file-cp1252.pl', 1);
    is $context->{context_line}, qq{print "this file contains cp1252: \x{fffd}\\n";};
  };
};

runtests;
