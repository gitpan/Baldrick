package Baldrick::Baldrick;
use strict;

BEGIN {
    our $VERSION     = '0.82';
    # use Exporter ();
    # use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);
    # @ISA         = qw(Exporter);
    # @EXPORT      = qw();
    # @EXPORT_OK   = qw();
    # %EXPORT_TAGS = ();

    use Socket;
    use Carp;
    use Data::Dumper;               # installed?
    use Time::HiRes;                # installed?
    use DBI;                                # must install
    use Config::General; 

    use Baldrick::Turnip;
    use Baldrick::Util;
    use Baldrick::Request;
    use Baldrick::Session;
    use Baldrick::Database;
    use Baldrick::User;
    use Baldrick::UserLoader;
    use Baldrick::DBUserLoader;
    use Baldrick::InputValidator;
    use Baldrick::Dogsbody;
    use Baldrick::DungGatherer;
    use Baldrick::TemplateAdapterBase;
    use Baldrick::SpecialTurnip;
    use Baldrick::TurnipWagon;
    use Baldrick::App;
}

1;
