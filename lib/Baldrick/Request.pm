# 
# Baldrick::Request - everything related to one HTTP request - 
# CGI, Session, User, etc.

# created by App->getNextRequest();
#

package Baldrick::Request;

use Data::Dumper;
use CGI;
use strict;
use FileHandle;
use Baldrick::Util;
use POSIX;

our @ISA = qw(Baldrick::Turnip);

sub init
{
    my ($self, %args) = @_;
    $self->SUPER::init(%args, 
        copyDefaults => { 
            mode => 'cgi',      # 'cgi' or 'apache'
            printer => 0        # an object that implements print(); ordinarly null.
        }
    );

    if (my $ar = $args{apachereq})
    {
        $self->{_apachereq} = $ar;
        $self->{_printer} = $ar;
    } 

	$self->{_didheader} = 0;
	$self->{_sending_cookies} = { };
    $self->{_contents} = {};

    return $self;
}

sub loadFromFile # ($filename)
# load from a file left by a previous call to saveInputs()
{
    my ($self, $filename) = @_;

    my $fileContents = loadConfigFile($filename); 
    my $contents = $fileContents->{BaldrickRequest} || $self->abort(
        "no BaldrickRequest section in inputs file $filename");

    if (my $e = $contents->{environment})
    {
        map { $ENV{$_} = $e->{$_}; } keys %$e;
    } else { 
        $self->abort( "no environment in inputs file $filename");
    }

    if (my $p = $contents->{parms})
    {
        map { $self->put($_, $p->{$_}); } keys %$p;
    } else {    
        $self->abort( "no request parms in inputs file $filename");
    }

    if (my $ssn = $contents->{session})
    {
    	# Session::init() looks for request->{SESSION_DATA}, request->{SESSION_ID}.
    	# If found they are simply copied into Session, and the usual file load and 
    	# security checks are skipped.
        $self->{SESSION_DATA} = $ssn;
        $self->{SESSION_ID} = $ssn->{_SESSION_ID} || $contents->{SESSION_ID} || 
            $self->get("session") || sprintf("%8x", int(rand(0xffffffff)));
    } else {    
        # DONTCARE - Session is OPTIONAL.
    }

    $self->_setPaths();
    return 0;
}

sub load # ( [ cgi_object => cgi ] )
# This is called by Baldrick::App just after initialising the request.  
# Loads Request with user-supplied values from web server. 
{
	my ($self, %args) = @_;

	if ($self->{_mode} eq 'apache')
	{
		$self->{_cgi_object} = $args{cgi_object} || new CGI();
	} else {	
		# DEFAULT MODE: CGI.
		# Be very careful changing the way it does this - need to 
		# ensure that 404 handlers (where the original path may be shit)
		# still work.
		$self->{_cgi_object} = $args{cgi_object} || new CGI();
	}

    if (my $cgi = $self->{_cgi_object})
    {
		$self->{_contents} = $cgi->Vars();
        $self->_setPaths(); # store current URL in a few places
    }

	$self->_trimSpacesFromContents();

	return ($self);
}

sub _setPaths # ()
# Save current URL as _path and _fullpath.
{
    my ($self) = @_;
    $self->{_path} = $ENV{SCRIPT_NAME} || $ENV{REQUEST_URI} 
			|| $ENV{SCRIPT_FILENAME} || $0;
	$self->{_fullpath} = $self->{_path} . $ENV{PATH_INFO};
}

sub DESTROY # ()
{
	my ($self) = @_;
	$self->finish(fromapp=>2);
}

sub finish # ()
# Free up resources.  Doesn't terminate the program.
{
	my ($self, %opts) = @_;

	return 0 if ($self->{_finished});

	if (! $opts{fromapp})
	{
		$self->setError("please don't call request->finish() directly, do app->finishRequest() instead");
	}
	
	if (defined ($self->{_session}) )   # deprecated?
	{
		$self->{_session}->finish();
		delete $self->{_session};
	}
	delete $self->{_cgi_object};
	delete $self->{_contents};
	
	$self->{_finished} = 1;
}

sub _trimSpacesFromContents # ()
# trim leading/trailing spaces from all parms.
{
	my ($self) = @_;
	my $rp = $self->getContents();

	foreach my $k (keys %$rp)
	{
		$rp->{$k} =~ s/^\s+//;
	} 

	foreach my $k (keys %$rp)
	{
		$rp->{$k} =~ s/\s+$//;
	} 
	return 0;
}

sub _pushOntoHeaderList # ( listref(headername,headervalue) ) or (string) 
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

sub doHeader # ( [ session => .., ctype => .., headers => .., headerlist => ..] ) 
# arg	session => session object
# arg	ctype => content-type (default text/html)
# arg	headers => { 'header1'=>'value1' ... }	-- send arbitrary headers
# arg	headerlist => [ "header1:value1", "header2:value2 ] -- send arbitrary headers in a particular order
# arg	headerlist => [ [ 'header1', 'value1' ], ['header2', 'value2'], ...] -- same thing, but with sublists instead of strings.
{
	my ($self, %args) = @_;
	if ($self->didHeader())
    {
        return 0 unless ($args{force});
    } 

	my $cgi = $self->{_cgi_object};

	my @myheaders;	# Our Output.

	# first send any headers that the app specified in 'headerlist'
	if ($args{headerlist})
	{
		foreach my $hdr (@{ $args{headerlist} })
		{
			_pushOntoHeaderList(\@myheaders, $hdr);
		} 
	}

	# do the same for 'headers' hash.
	if ($args{headers})
	{
		foreach my $k (keys %{ $args{headers} }) 
		{
			_pushOntoHeaderList(\@myheaders, "$k:" . $args{headers}->{$k});
		} 
	} 

	# Session ID.	
	push (@myheaders, $args{session}->getHeader())
		if ($args{session});

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
	$self->sendOutput( \$hdrs);

    # FIXME: use modperl for this if available...

	$self->{_didheader} = 1;
	return 1;
}

sub sendOutput # ( $$text : REFERENCE to text string) return 0
# text is passed by reference to avoid huge things on stack!
{
	my ($self, $textref) = @_;

    if (my $p = $self->{_printer})
    {
	    $p->print($$textref);
    } else {
	    print $$textref;
    } 
	return 0;
}

# Accessors referencing standard web environment vars.
sub getDocumentRoot
{
    return $ENV{DOCUMENT_ROOT};
}

sub getUserAgent
{
	return $ENV{HTTP_USER_AGENT};
}

sub getRemoteHost
{
	return $ENV{REMOTE_HOST} || $ENV{REMOTE_ADDR};
}

sub getRemoteUser
{
	return $ENV{REMOTE_USER};
}

sub getServerName   # ()
{
    return $ENV{SERVER_NAME};
}

sub getProtocol # () return "http" | "https"
{
    my ($self) = @_;
    if ($ENV{SCRIPT_URI} =~ m#^([a-z]+):#)
    {
        return $1;
    } 
    
    # Not good, but try to return *something*.
    return 'https' if ($ENV{SERVER_PORT} =~ m/44\d/);   # 443, 444...
    return 'http';  
}

sub getCGI # ()
{
	my ($self) = @_;
	return $self->{_cgi_object};
}

sub getBaseDirectory # Return the directory where the script is installed.
{
    my ($self) = @_;
    my $here = $ENV{SCRIPT_FILENAME};
    $here =~ s#/[^/]+$##;   
    return $here;
}

sub getPath # ( full => 0 | 1 )
{
	my ($self, %args) = @_;
	if ($args{full})
	{
		return $self->{_fullpath};
	} else {
		return $self->{_path};
	}
}

sub getPathInfo
{
    return $ENV{PATH_INFO}; 
}

sub getParameters { return Baldrick::Turnip::getContents(@_); } # deprecated, use getContents()
sub getParameter  { return Baldrick::Turnip::get(@_); } # deprecated, use get()
sub setParameter  { return Baldrick::Turnip::put(@_); } # deprecated, use put()

sub getCookie # ($cookie-name) return cookie-value or ''.
{
	my ($self, $name) = @_;

	my $allc = $ENV{HTTP_COOKIE};
    my @allc = split (/\s*;\s*/, $allc ? $allc : "");
    my ($k,$v);
    foreach my $c (@allc)
    {
        ($k,$v)=split(/=/, $c, 2);
        return $v if ($k eq $name);
    }
    return '';
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

sub getRemoteIP # () return string like '1.1.1.1', default 127.127.127.127
{
	my ($self) = @_;
	my $rv = $ENV{REMOTE_ADDR};
	
	# Must sanitize input - digits, dot, colon (for IPv6) only.
    if ( $rv =~ m#([\d\.:]+)# )
    {
        return $1;
    } 
	
	$self->writeLog("malformed IP $rv", notice => 1);
	return '127.127.127.127';
}

sub saveInputs 
# Save user's inputs and state (parameters, environment, session) to a text file, 
# that can later be sucked back into loadInputs().
{
	my ($self, %args) = @_;

	# I. Determine filename to dump to.   
	my $remote = $self->getRemoteIP();
	
    my $filename = '';
	if (my $fn = $args{filename})
	{
        return 0 if ($fn eq 'none');
		$filename = Baldrick::Util::replaceDateWords( $fn );
	} elsif (my $fp = $args{fileprefix}) {
        return 0 if ($fp eq 'none');
		$filename = $fp . Baldrick::Util::replaceDateWords("SHORTDATE_SHORTTIME_$remote.dump");
	} elsif (my $hnd = $args{handler}) {
		my $prefix = ref($hnd);
		$prefix =~ s/.*:://g; # don't want namespace.
		$filename = $prefix . Baldrick::Util::replaceDateWords("SHORTDATE_SHORTTIME_$remote.dump");
	} else {
		$filename = Baldrick::Util::replaceDateWords("BALDRICK.SHORTDATE_SHORTTIME_$remote.dump");
	}

	if ($filename)
	{
		$filename = "/tmp/$filename" unless ($filename =~ m#^/#);
	}  else {	
		requireAny(\%args, [ qw(filename fileprefix handler) ]);
	}
	
	# II. Write it!
	my $fh = new FileHandle();
	if ($fh->open(">>$filename"))
	{
		$fh->print("<BaldrickRequest>\n");
        
        $self->_saveInputsWriteObj($fh, 'parms', $self->getContents());
        $self->_saveInputsWriteObj($fh, 'environment', \%ENV);
        if (my $ss = $args{session})
        {
        	$fh->printf(qq|SESSION_ID="%s"\n|, $ss->getID());
            $self->_saveInputsWriteObj($fh, 'session', $ss->getContents());
        }

        $fh->print("</BaldrickRequest>\n");		
		$fh->close();
	} else {
		$self->abort("cannot write $filename: $!");
	}	
	
	$self->{saved_inputs_file} = $filename;
	return $filename;
}

sub _saveInputsWriteObj # ($filehandle, $label, \%hash)
# Used by saveInputs to write request-parameters, session-contents, or environment
{
    my ($self, $fh, $label, $obj) = @_;

	print $fh "<$label>\n";
	foreach my $k (sort keys %$obj)
	{
		my $val = $obj->{$k};
		$val =~ s#"#\\"#g;        # backslash quotes.
		$fh->print(qq|\t$k = "$val"\n|);
	}
	print $fh "</$label>\n";
	return 0;
}

sub createURL # ( [ proto => .. , server => .., port => .., path => .., querystring => .., parms => .., copyParms => 0|1 ] )
# Construct any URL.  Each of the parameters, if missing, defaults to value of current request.
{
    my ($self, %args) = @_;

    my $proto = $args{proto} || 'http';
    my $server = $args{server} || $self->getServerName();
    $server .= ":$args{port}" if ($args{port} && $args{port}!=80);
    
    my $path = $args{path} || $self->getPath(full => 1);
    $path =~ s#^/##;

    my $qs = $args{querystring};

    # parms => HASH -- copy each of these key/value pairs as-is.
    if (my $parms = $args{parms})
    {
        foreach my $k (keys %$parms)
        {
            $qs .= sprintf("%s=%s&", CGI::Util::escape($k),     
                CGI::Util::escape($parms->{$k}));
        } 
    }  
    
    # copyParms => LIST -- foreach param in list, copy OUR OWN value for it.
    if (my $keylist = $args{copyParms})
    {
    	$keylist = [ keys( %{ $self->getContents() } ) ] if ($keylist eq 'ALL');
        foreach my $k (@$keylist)
        {
            $qs .= sprintf("%s=%s&", CGI::Util::escape($k),     
                CGI::Util::escape($self->get($k)));
        } 
    }  
    
    # assemble it.
    return sprintf("%s://%s/$path?%s",
        $proto, $server, $qs);
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
