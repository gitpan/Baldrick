package Baldrick::Baldrick;
use strict;

BEGIN {
    our $VERSION     = '0.85';
    # use Exporter ();
    # use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);
    # @ISA         = qw(Exporter);
    # @EXPORT      = qw();
    # @EXPORT_OK   = qw();
    # %EXPORT_TAGS = ();

    use Socket;
    use Carp;
    use Data::Dumper;              
    use Time::HiRes;              
    use DBI;                     
    use Config::General; 

    use Baldrick::Turnip;
    use Baldrick::Util;
    use Baldrick::Response;
    use Baldrick::Request;
    use Baldrick::Session;
    use Baldrick::Database;
    use Baldrick::User;
    use Baldrick::UserLoader;
    use Baldrick::DBUserLoader;
    use Baldrick::InputValidator;
    use Baldrick::Dogsbody;
    use Baldrick::DungGatherer;
    use Baldrick::TemplateAdapter;
    use Baldrick::SpecialTurnip;
    use Baldrick::TurnipWagon;
    use Baldrick::App;
}

=head1 NAME

Baldrick::Baldrick - Baldrick Application Framework Loader

=head1 SYNOPSIS

  use Baldrick;

=head1 DESCRIPTION

Baldrick.pm is the loader for the Baldrick Application Framework.

Baldrick::Stub.pm loads Baldrick.pm, and also provides the main() for a Baldrick
module.  See "perldoc Baldrick::Stub".

=head1 AUTHOR

    Matt Hucke
    CPAN ID: HUCKE
    hucke@cynico.net
    http://www.baldrickframework.org/

=head1 COPYRIGHT

This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the
LICENSE file included with this module.


=head1 SEE ALSO

Baldrick::Stub

http://www.baldrickframework.org/

=cut


1;
