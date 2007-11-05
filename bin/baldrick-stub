#!/usr/bin/perl

package Baldrick::Stub;
use strict;

use lib 'lib';  

exit(main());

######################################################
sub loadBaldrick
{
    my $fred = 'use Baldrick::Baldrick;';
    eval $fred;
    if ($@)
    {
        return errorPage($@, "SEVERE ERROR - CANNOT LOAD FRAMEWORK");
    }
    return 0;
}

sub main
{
    return -1 if (loadBaldrick() < 0);

    eval {
        my $app = new Baldrick::App();
        $app->run();
        $app->finish();
        $app=0;
    };
    if ($@)
    {
        return errorPage($@, 'RUNTIME ERROR');
    }
    return 0; 
}

sub errorPage
{
    my ($msg, $headline) = @_;

    print "Content-type: text/html\n\n";

    $headline ||= 'ERROR';
    print "<h2>$headline</h2>\n\n";
    print "$msg\n\n";
    return -1;
}

=head1 NAME

Baldrick::Stub

=head1 SYNOPSIS

  $ cd /var/www/my-website/cgi-bin
  $ cp [Baldrick-Installation-Directory]/Stub.pm baldrick-stub
  $ ln -s baldrick-stub [my-program-name]
  $ lynx http://www.mysite.com/cgi-bin/[my-program-name]

=head1 DESCRIPTION

  Baldrick::Stub is the main program for any Baldrick application.  It
  loads the Baldrick libraries, then creates an App object.

  You don't want to "use" this as a module - just copy it into your 
  CGI directory, and symlink to it every filename that the web server
  should invoke: "shop", "chat", "forum", "logout", whatever.

=head1 SEE ALSO

  See http://www.baldrickframework.org/book/Baldrick::Stub

=head1 AUTHOR 
    
  Matt Hucke (hucke@cynico.net)

=cut

1;
