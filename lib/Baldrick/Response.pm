
package Baldrick::Response;

use Data::Dumper;
use CGI;
use strict;
use FileHandle;
use Baldrick::Util;
use POSIX;

our @ISA = qw(Baldrick::Turnip);

our %redirectTypes = (
        301 => 'Moved Permanently', 
        302 => 'Found',
        303 => 'See Other',
        304 => 'Not Modified',
        307 => 'Temporary Redirect'
);

our $DUMP_ORDINAL = 0;  # for generating unique IDs for the various dump sections on a page.  

sub init
{
    my ($self, %args) = @_;
    $self->SUPER::init(%args,
        copyRequired => [ 'request' ],  
        copyDefaults => { 
            mode => 'cgi',      # 'cgi' or 'apache'
            printer => 0,        # an object that implements print(); ordinarly null.
            contents => {},
            recording => 0
        }
    );

    $self->{_didoutput} = 0;
    $self->{_didheader} = 0;
    $self->{_sending_cookies} = { };
    $self->{_responseHeaders} = [ ];    # headers we will send as "Name: Value"
    
    $self->{_savedOutputs} = [];         # remember everything output, if saveOutputs=1
    # my @caller = caller();
    # webdump(\@caller);
    # webdump($self);    
    return $self;
}

sub finish # ()
# Free up resources.  Doesn't terminate the program.
{
    my ($self, %opts) = @_;

    return 0 if ($self->{_finished});
  
    delete $self->{_contents};
    delete $self->{_printer};
    
    $self->{_finished} = 1;
}

sub startRecording
{
    my ($self) = @_;
    $self->{_recording} = 1;
}

sub getSavedOutput  # return LISTREF of text chunks
{
    my ($self) = @_;
    return $self->{_savedOutputs};
}

sub setPrinter
# when running mod_perl printer is an Apache2::RequestRec
# without mod_perl printer is 0.
{
	my ($self, $p) = @_;
	$self->{_printer} = $p;
}

sub getPrinter
# when running mod_perl printer is an Apache2::RequestRec
# without mod_perl printer is 0.
{
	return $_[0]->{_printer};
}

sub getResponseHeaders
{
    return $_[0]->{_responseHeaders};
}

sub addResponseHeader   # (fullheader => "HeaderName: HeaderContents")
{
    my ($self, %args) = @_;
       
    my $rh = $self->getResponseHeaders();
    if ($args{fullheader})
    {
        push (@$rh, $args{fullheader});
    } else {
        requireArg(\%args, 'fullheader');   # abort.
    }
    return 0;
}

sub _pushOntoHeaderList # ( listref(headername,headervalue) ) or (string)  # STATIC.
# This is used when assembling a final header list preparatory to writing it out.
{
    my ($hlist, $stuff) = @_;
    if (ref($stuff))
    {
        push (@$hlist, "$stuff->[0]:$stuff->[1]");
    } else {
        push (@$hlist, $stuff);
    }
}

sub didHeader # () return 1 or 0 if did header already.
{
    return ($_[0]->{_didheader} || 0);
}

sub didOutput # ()
{
    return ($_[0]->{_didoutput} || 0);
}

sub doHeader # ( [ session => .., ctype => .., headers => .., headerlist => ..] ) 
# arg   ctype => content-type (default text/html)
# arg   headers => { 'header1'=>'value1' ... }  -- send arbitrary headers
# arg   headerlist => [ "header1:value1", "header2:value2 ] -- send arbitrary headers in a particular order
# arg   headerlist => [ [ 'header1', 'value1' ], ['header2', 'value2'], ...] -- same thing, but with sublists instead of strings.
{
    my ($self, %args) = @_;
    
    if ($self->didHeader())
    {
        return 0 unless ($args{force_header});
    } 

    my @myheaders;  # Our Output.

    # Begin with the headers that have been previously stashed via addResponseHeader().
    # This will almost always include the Set-Cookie: that sends the session ID.
    if (my $rh = $self->getResponseHeaders())
    {
    	foreach my $hdr (@$rh)
        {
            _pushOntoHeaderList(\@myheaders, $hdr);
        }
    }

    # Now add any that are being sent in our parameters right now
    #   args{headerlist} is a listref of "Name: Value" 
    if (my $hl = $args{headerlist})
    {
        foreach my $hdr (@$hl)
        {
            _pushOntoHeaderList(\@myheaders, $hdr);
        } 
    }

    # do the same for 'headers' hash.
    if (my $hh = $args{headers})
    {
        foreach my $k (keys %$hh) 
        {
            _pushOntoHeaderList(\@myheaders, "$k:" . $hh->{$k});
        } 
    } 

    # Various cookies.
    my $clist = $self->{_sending_cookies};
    foreach my $cname (keys %$clist)
    {
        push (@myheaders, "Set-Cookie: $cname=$clist->{$cname}");
    } 

    # And finally the content type.
    my $ct = $args{ctype} || 'text/html';
    push (@myheaders, "Content-type: $ct");

    # BUILD AND SEND.
    for (my $jj=0; $jj<=$#myheaders; $jj++)
    {
        chomp($myheaders[$jj]);
    } 

    # Must send it all with a single write op.
    my $hdrs = join("\n", @myheaders) . "\n\n" ;
    $self->sendText(\$hdrs, is_header => 1);

    # REMEMBER WE DID SOMETHING.
    $self->{_didheader} = 1;
    $Baldrick::Util::DID_WEBHEAD = 1;   # so the global webprint doesn't do its own headers.
    
    return 1;
}

sub sendText # ( string | reference-to-string ) return 0
# Sends output via _printer if defined
{
    my ($self, $text, %args) = @_;

    my $realText = ref($text) ? $$text : $text;
    
    my $p = $self->getPrinter();
    if ($p && $p->can('print'))
    {
        $p->print( $realText );
    } else {
        print $realText;
    }
   
    if (! $args{is_header})
    {
        $self->{_didoutput}++;
        if ( $self->{_recording} )
        {
    	    push( @{ $self->{_savedOutputs} }, $realText);
        }
    }  
    return 0;
}

sub doRedirect  # ($url, [code => 301|..] 
{
	my ($self, $where, %args) = @_;
	
#   print "Location: $where\n";

    my $code = $args{code} || 301;
    my $msg = $redirectTypes{$code} || $redirectTypes{301};

    if ($self->didHeader())
    {
    	my $t = qq#This page has moved <a href="$where">here</a>.#; 
        $self->sendText(\$t);
    } else {
        $self->doHeader(
            headerlist => [ 
                "Status: $code $msg",
                "Location: $where"
            ]
        );
        $self->{_didoutput} = 1;
    }
    return 0;
}
    
sub setCookie
# This just stashes it for later.  doHeader() will eventually
# be called, and we send the cookies then.
{
    my ($self, $name, $value) = @_;

    my $clist = $self->{_sending_cookies};
    $clist->{$name} = $value;
    return 0;
}


##### STATICS ###############################################################

sub staticFormatCookieDate # ( $time-since-epoch )
# Format a date appropriately for the 'expires' field of a Set-Cookie header.
{
    my ($time) = @_;
    
    #  DAY, DD-MMM-YYYY HH:MM:SS GMT
    my @expire = gmtime($time);
    my $rv = POSIX::strftime("%a, %d-%b-%Y %H:%M:%S", @expire);
    return "$rv GMT";
}

1;

=head1 NAME

Baldrick::Response - sends content to web browser

=head1 SYNOPSIS

    my $rsp = $dogsbody->getResponse();
    
=head1 DESCRIPTION
   
    Response is generally called by Baldrick::Dogsbody's sendOutput() 
    function, where it receives output already formatted by the 
    appropriate TemplateAdapter.
    
=cut

