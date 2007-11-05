
###  MAIN ENTRY POINT FOR MOD_PERL ####

# For Apache ModPerl applications, this class is called by the web server.
# It loads the other libraries and creates an App object.

package Baldrick::Trousers;

use lib '..';
use Baldrick::Baldrick;
use Baldrick::Util;
use Data::Dumper;
use strict;
use Apache2::Const;

our @ISA = qw(Baldrick::Turnip);
our $COUNTER = 0;

sub handler : method
{
    my $class = ($#_ >= 1) ? shift(@_) : 'Baldrick::Trousers';
    my ($r) = @_;

    $COUNTER++;

    my $app = 0;
    my $req = 0;
    eval {
        $app = getApp($r) || die("no app");
        $req = $app->getNextRequest(mode => 'apache', apachereq => $r) || die("no request");
    }; 

    if ($@)
    {
        my $err = $@;
        $r->print("Content-type: text/html\n\n");
        $r->print("<h2>$class Accident</h2>\n<p>$err</p>");
        return Apache2::Const::SERVER_ERROR;
    } 

    if ($app && $req)
    {
        $app->handleRequest($req);
        $app->finishRequest($req);
    } else {
        return Apache2::Const::SERVER_ERROR;
    }

    return Apache2::Const::OK;
}

sub getApp
{
    my ($r) = @_;

    # Get an app from the pool (a very shallow pool - currently one app per process)
    my $app = Baldrick::App::getAppObject();
   
    # See if it wants to perform.    
    if (!$app)
    {
    } elsif ($app->isFinished()) {
        $app = 0;
    } elsif (! $app->canDoMoreRequests() ) {
        $app->finish();
        $app=0;
    } 

    if (!$app)
    {
        $app = new Baldrick::App( mode => 'apache', maxrequests => -1, printer => $r  );
    }
    return $app;
}

1;
