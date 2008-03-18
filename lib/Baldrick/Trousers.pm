
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
use Time::HiRes qw(gettimeofday tv_interval);

our @ISA = qw(Baldrick::Turnip);
our $COUNTER = 0;

sub handler : method
{
    my $class = ($#_ >= 1) ? shift(@_) : 'Baldrick::Trousers';
    my ($r) = @_;

    my $t0 = [ gettimeofday() ];

    $COUNTER++;

    my $app = 0;
    my $req = 0;
    eval {
        $app = getApp($r) || die("no app");
        $req = $app->getNextRequest(mode => 'apache', apache_request => $r) || die("no request");
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
        eval {
            my $logger = new Baldrick::Turnip(force_init => 1, logprefix => $class);
    
            my $t1 = [ gettimeofday() ];

            $logger->openLog(file => "/tmp/mod-perl.log");
            $logger->writeLog(sprintf(
                "$$.$COUNTER: handled request for %s from %s session=%s t=%f",
                $req->getPath(), $req->getRemoteIP(), $req->get("session"),
                tv_interval($t0,$t1))
            );
            $logger->closeLog();
            $logger->finish();
            $logger=0;
        };
        if ($@)
        {
            print STDERR "$class: writelog error $@\n";
        } 
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
