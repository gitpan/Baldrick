# Baldrick::Session

# v1.0 2005/06
# v1.1 2006/07 added Captcha support via Authen::Captcha
# v2.0 2007/08 major rewrite
# v2.01 2007/10 cookie expire, minor changes to cleanup config

# abstract base class for FileSession, DatabaseSession, etc..

package Baldrick::Session;

use strict;
use Baldrick::Util;
use Baldrick::Turnip;

our @ISA = qw(Baldrick::Turnip);

our @reservedKeys = qw(SESSION_IP SESSION_HOST SESSION_CREATED SESSION_UPDATED SESSION_USERAGENT SESSION_HIJACKED);

my %DEFAULTS = (
    'idstyle' => 'hex16', 
    'cookie-name' => 'bldkssid',
    'parameter-name' => 'session', 
	'cookie-path' => '/', 
	'lifespan' => '2d',
	'max-idle-time' => '4h', 
	'cookie-expire' => 'none',     # When the cookie expires; may be entirely different from max-idle-time.
    'cleanup-frequency' => 1,
    'cleanup-password' => '',        # value of cgi param SESSION_CLEANUP
    'cleanup-action' => 'delete', 
    'verify-user-agent' => 'true',  # true / false 
    'verify-ip' => 'true',  # true / false / strict
    'hijack-password' => '', # if set, allow admins to take over a user session
);

sub init
{
    my ($self, %args) = @_;

    $self->SUPER::init(%args, 
        copyRequired => [ qw(config) ],
        copyDefaults => { 
            servername => $ENV{SERVER_NAME}, 
            debug => 0,
            logprefix => "[" . ref($self) . ":$ENV{REMOTE_ADDR}:init]",
            config_defaults => \%DEFAULTS, 
        } 
    );

    $self->{_debug} ||= $self->getConfig('debug');
   
    # if 'logfile' or 'debug' set, use a private log file. 
    if (my $lf = $self->getConfig('logfile'))
    {
        $self->closeLog();
        $self->openLog(file => $lf);
    } elsif ($self->{_debug}) {
        $self->closeLog();
        eval {
            $self->openLog(file => "/tmp/sessions.log");
        };
    }
    
    $self->{_sid} = 0;          # session ID
    $self->{_sid_changed} = 0;  # session ID has changed during this request
    $self->{_changed} = 0;  # increment on put(), reset on load()
    $self->{_type} = $args{type} || $self->{_config}->{type};
    $self->{_contents} = {};
    $self->{_forceCleanup} = 0; # open() may set this to 1 if password is given.

    $self->setCookieName($self->getConfig("cookie-name"));
    $self->setParameterName($self->getConfig("parameter-name"));

    if (my $req = $args{request})
    {
        if ($req->{SESSION_ID})
        {
            $self->{_forcedSessionID} = $req->{SESSION_ID};
        }
        if ($req->{SESSION_DATA})
        {
            $self->{_contents} = $req->{SESSION_DATA};
            $self->{_preloaded} = 1;
        } 
    } 

    return $self;
}

sub DESTROY
{
	my ($self) = @_;
    $self->finish();    # will do write() if necessary.
	$self->{_config}=0;
}

sub _reset # () -- empty contents and zero the SID.
{
    my ($self) = @_;
    $self->{_contents} = {};
    $self->{_sid} = 0;
}

sub getID { return $_[0]->{_sid}; }
sub getId { return $_[0]->{_sid}; } # alias for the forgetful

sub setID
# Saves ID in both $self->{_sid} and request->{_contents}->{session}
{ 
    my ($self, $sid, %args) = @_;

    $self->{_sid} = $sid;
    my $remaddr = $args{request} ? $args{request}->getRemoteIP() :
        $ENV{REMOTE_ADDR};

    $self->{_logprefix} = "[" . ref($self) . ":$remaddr:$sid]";
   
    if (my $req = $args{request})
    {
        $req->put( $self->getParameterName(), $sid);
    } 
    return 0;
}

sub getType { return $_[0]->{_type}; }

sub getCookieName       { return $_[0]->{_cookieName}; }
sub setCookieName       { $_[0]->{_cookieName} = $_[1]; }
sub getParameterName    { return $_[0]->{_paramName}; }
sub setParameterName    { $_[0]->{_paramName} = $_[1]; }
sub hasChanged          { return $_[0]->{_changed}; }

sub _assertNullType
# Assert that the current Session object has a type of 'null'.
# This forces derived types to override the essential functions of load, write, idInUse
{
    my ($self) = @_;

    if ($self->getType() ne 'null')
    {
        my @caller = caller(1);
        $self->abort(ref($self) . ": don't know how to " . $caller[3]);
    } 
    return 0;
}

sub load
# Wrapper for _loadAnySession that then copies contents into $self->{_contents}.
# Allows loadAnySession to operate without touching _contents.
{
    my ($self) = @_;

    my %contents = ();

    my $rv = $self->_loadAnySession(sid => $self->getSID(), out => \%contents);
    if ($rv==0)
    {
        $self->{_contents} = \%contents;
    } else {
        $self->_reset();
    }
    return $rv;
}

sub open # ( request => ..., %args ) 
# Main entry point called by App.
# Load session contents based upon values from request (CGI, cookie, etc.)
# -cgivars => cgi hashref from $CGI->Vars()
{
    my ($self, %args) = @_;

    my $request = requireArg(\%args, 'request');

    $self->__initForceCleanup($request);

    ## Check to see if a session ID is present in the request.
    # If not, create a new one.
    my $sidWanted = $self->_getDesiredSID(%args);
    if (! $sidWanted) 
    {
        $self->mutter("No session ID found; will create new session.");
        return $self->_startSession(%args);
    }

    # At this point, a session ID has been found.  Try to reattach to it.
    $self->mutter("wants to use SID $sidWanted");

    # 'preloaded' is used when SESSION_DATA is present in the Request object.
    # Don't load from file/database/whatever; just use _contents already there.
    if ($self->{_preloaded})
    {
        # my %junk;
        # my $err = $self->_loadAnySession(sid => $sidWanted, out => \%junk); 
        $self->setID($sidWanted, %args);
        return 0;
    } 

    my %contents = ();
    my $err = $self->_loadAnySession(sid => $sidWanted, out => \%contents);

    $self->mutter("loading SID $sidWanted, status=$err");
    if ($err)
    {
        # Failed to load; start a new session.
        return $self->_startSession( %args, old_id => $sidWanted );
    }

    # Loaded file/database OK; set loaded contents to be our contents.
    $self->{_contents} = \%contents;

    # Check to see that this is probably same user as before.
    $err = $self->_verifyClientInfo(%args, sid => $sidWanted);
    if ($err)
    {
        $self->_reset();
        return $self->_startSession( %args, old_id => $sidWanted );
    }

    # SUCCESS!  Only now do we set the session ID, enabling write() to work.
    $self->setID($sidWanted, %args);
    return 0;
}

sub finish # ()
{
    my ($self) = @_;

    # Flush this session.
    if ($self->{_changed})
    {
        $self->put("SESSION_UPDATED", easyfulltime());
        $self->write();
    }

    return 0 if ($self->{_finished});

    # Do some maintenance on all sessions, not just this user's...
    my $shouldClean = $self->{_forceCleanup};

    # if _forceCleanup isn't set, check random number to see if we should
    # do it anyway.
    if (!$shouldClean)
    {
        my $freq = $self->getConfig("cleanup-frequency");
        if ($freq eq 'never' || $freq eq 'none')
        {
        	$shouldClean = 0;
        } else {
            $shouldClean = ($freq && (0 == int(rand($freq)))) ? 1 : 0;
        }
    }

    $self->doOldSessionCleanup() if ($shouldClean);

    $self->SUPER::finish(); # closes log file.
    return 0;
}

sub doOldSessionCleanup
# Clean up OTHER sessions that have expired.
{
    my ($self) = @_;

    return 0 if ($self->{_type} eq 'null');

    my $lifespan = parseTimeSpan(
            $self->getConfig("lifespan")
    );
    my $maxidle = parseTimeSpan(
            $self->getConfig("max-idle-time")
    );

   
    my $starttime = time();
 
    $self->writeLog("session-cleanup: starting, lifespan=$lifespan, maxidle=$maxidle");

    my $count = $self->cleanupExpired( 
        lifespan => $lifespan, maxidle => $maxidle );

    my $msg = sprintf("session-cleanup: deleted %d sessions in %d seconds",
        $count, time() - $starttime);
    $self->writeLog($msg);

    # if admin initiated via SESSION_CLEANUP=(password), print it to user too.
    print "<b>$msg</b>\n" if ($self->{_forceCleanup});
}

sub cleanupExpired
# Cleanup session records that have exceeded the allowable lifetime.
{
    my ($self) = @_;
    $self->_assertNullType();
    return 0;
}

sub _idInUse
{
    my ($self) = @_;
    $self->_assertNullType();
    return 0;
}

sub _loadAnySession
{
    my ($self) = @_;
    $self->_assertNullType();
    return 0;
}

sub create
# create() is a wrapper to call write() for the first time for each session.
# write() may behave differently, such as insisting that a file not 
# exist already, or doing database INSERT's instead of UPDATE's.  
{
    my ($self, %args) = @_;
    return $self->write(%args, create => 1);
}

sub write
# Placeholder write for NULL session object type.
{
    my ($self) = @_;
    $self->_assertNullType();
    return 0;
}

sub _load
# Placeholder LOAD for NULL session object type.  Always fails, provoking
# creation of a new session.
{
    my ($self) = @_;
    $self->_assertNullType();
    return 1;
}

sub clear
{
    my ($self) = @_;

    return $self->clearContents(preserve => \@reservedKeys);
}

sub getHeader	# ( [parts => ..] ) return string or listref
# returns "Set-Cookie: ...\n"
{
	my ($self, %args) = @_;

    my $left = "Set-Cookie";
    my $right = sprintf("%s=%s; path=%s;",
        $self->getCookieName(),
        $self->getID(), 
        $self->getConfig("cookie-path", defaults => \%DEFAULTS)
    );

	my $ls = $self->getConfig("cookie-expire", defaults => \%DEFAULTS);
	if ($ls && ($ls ne 'none') && ($ls ne 'perm'))
	{
		my $secs = parseTimeSpan($ls);
		if ($secs > 60)   # ignore anything under 60s, that's silly.
		{
			$right .= sprintf(" expires=%s;", Baldrick::Response::staticFormatCookieDate(time() + $secs));			
		} 	
	}
	
	$right .= "\n";
    if ($args{parts} > 1)
    {
        return [ $left, $right ];
    } else {
        return "$left: $right";
    }
}

sub allocateSessionID # () return string-sessionid 
# Allocate a Session ID that is not already in use.
{
	my ($self) = @_;
	my $tries=0;

    my $idstyle = $self->getConfig('idstyle');

	do 
	{ 
		my $sid = 0;

		if ($idstyle eq 'old')
		{
			# old: 6-10 digit decimal (for compatibility with my pre-baldrick library)
			$sid = int (abs(100000 +  rand ( 0x70000000 - 100000 ))); 
		} else {    # hex16
			# new: 16-digit hex number.
			$sid = sprintf("%04x%04x%04x%04x", 
				int (rand(0xFFFF)), int (rand(0xFFFF)),
				int (rand(0xFFFF)), int (rand(0xFFFF))
			);
		} 

		if (! $self->_idInUse($sid) )    # subclass determines this.
		{
			return $sid;
		} 
	} while ($tries++ < 10000);	 

	$self->abort("$0: too many tries to allocate unique sid");
}

sub _initSessionContents
{
	my ($self, %args) = @_;

    $self->{_contents} = {};

    my $req = requireArg(\%args, 'request');

    my $ft = easyfulltime();
    $self->put ('SESSION_CREATED', $ft);
    $self->put ('SESSION_UPDATED', $ft);

    $self->put ('SESSION_IP', $req->getRemoteIP() );
    $self->put ('SESSION_HOST', $req->getRemoteHost() );

    $self->put ('SESSION_USERAGENT', __cleanUserAgent($req->getUserAgent()));

    $self->writeLog($self->get('SESSION_IP') . " " . 
        $self->get('SESSION_USERAGENT') );

    return 0;
}

sub __cleanUserAgent
{
    my ($ua) = @_;
    $ua =~ s/\s+/_/g;
    return $ua; 
}

sub _startSession
# Start a new session: allocate ID, populate with new contents, and 
# call write() to establish in filesystem/database/whatever.
{
    my ($self, %args) = @_;

    $self->mutter("startSession called");

    $self->_reset(); 
    $self->_initSessionContents(%args);

    my $tries = 0;
    do {
        my $newsid = $self->allocateSessionID() || $self->abort("could not allocate SID");

        $self->setID($newsid);

        $self->mutter("allocated new session ID $newsid for $ENV{REMOTE_ADDR}");
        if (0 ==  $self->create() )
        {
            # SUCCESS - write it to request object also. 
            $self->setID($newsid, %args);
            $self->{_sid_changed} = 1;
            return 0;    # SUCCESS.
        } else {
            $self->setID(0);
        }
    } while ($tries++ < 1000);

    $self->abort("failed to start session");
}

sub __verifyFailure  # ($msg) PRIVATE
# Provides return (with logging) for _verifyClientInfo
{
    my ($self, $msg) = @_;

    $self->_reset();    # superfluous reset for safety!
    $self->{_verificationFailed} = $msg;
    $self->mutter($msg);
    $self->writeLog($msg, warning => 1);
    return -1;
}

sub _isHijacked
{
    my ($self, %args) = @_;

    my $req = $args{request} || return 0;
    my $ip = $args{ip} || return 0;

    # Check to see if it was hijacked on a previous request.
    if ($ip eq $self->get("SESSION_HIJACKED"))
    {
        $self->writeLog("ALERT: This is a session previously hijacked by $ip");
        return 1;
    }  

    my $trypw = $req->get("SESSION-HIJACK");
    return 0 if (!$trypw);

    my $pw = $self->getConfig("hijack-password-$ip", defaultvalue => '');
    return 0 if (!$pw);
    return 0 if (length($pw) < 6);
    return 0 if ($pw ne $trypw);
 
    $self->writeLog("ALERT: User at $ip is hijacking session"); 
    $self->put("SESSION_HIJACKED", $ip);
    return 0;
}

sub _verifyClientInfo
{
    my ($self, %args) = @_;

    my $req = requireArg(\%args, 'request');

    my $ip1 = $self->get('SESSION_IP');
    my $ip2 = $req->getRemoteIP();
    my $ua1 = $self->get('SESSION_USERAGENT');
    my $ua2 = __cleanUserAgent($req->getUserAgent());
        
    return 0 if (
        $self->_isHijacked(
            request => $req, ip => $ip2, sid => $args{sid})
    );

    my $ipRule = $self->getConfig('verify-ip');
    if ( $ipRule eq 'strict' || seekTruth($ipRule) )
    {
        if ($ipRule ne 'strict')
        {
            $ip1 =~ s/\d+$//;       # trim last octet
            $ip2 =~ s/\d+$//;       # trim last octet
        }
        if ($ip1 ne $ip2)
        {
            return $self->__verifyFailure("IP Mismatch: '$ip1' != '$ip2'");
        } 
    } 

    if (seekTruth($self->getConfig('verify-user-agent')))
    {
        if ($ua1 ne $ua2)
        {
            return $self->__verifyFailure("Agent Mismatch: '$ua1' != '$ua2'");
        } 
    } 

    ## SUCCESS - ALL MATCHES.
    return 0;
}

sub isWellFormedSID
{
    my ($self, $sid) = @_;

    my $idstyle = $self->getConfig('idstyle');
    if ($idstyle eq 'old')
    {
        return 1 if ($sid =~ m/^[0-9]{6,10}$/);
    } else {    # hex16
        return 1 if ($sid =~ m/^[0-9a-fA-F]{6,10}$/);
    }
    return 0;
}

sub cleanSID
# Untaint a session ID so we can use it in a filename.
{
    my ($self, $sid) = @_;
  
    if ($sid && ($sid =~ m/([0-9a-fA-F]+)/))    
    {
        return $1;
    } 
    return 0;
}

sub __returnDesiredSID
{
    my ($self, $sid, $origin, $comment) = @_;

    if ($sid)
    {
        $self->{_sid_origin} = $origin;
    } elsif ($sid eq "0") {
        $self->{_sid_origin} = 'reset';
    } 
    return $self->cleanSID($sid);
}

sub _getDesiredSID # ( request => request-object )
# Determines the session ID from various clues in the environment: 
# session cookie, cgi variable, setup option 'forcesid'...
# returns: session ID if one is available, else zero.
{
    my ($self, %args) = @_;

	# LOCATION 1: _forcedSessionID.  This isn't available 
	# to most user programs; it's for use in admin tools to take over or 
	# examine a session.
    my $fsid = $self->{_forcedSessionID};
    if ($fsid)
    {
        return $self->__returnDesiredSID($fsid, 'force', 
            "forcing ID to $fsid");
    } 

	# LOCATION 2: cgi->{ sessionvariable } .
    my $req = requireArg(\%args, 'request');
    my $reqsid = $req->get( $self->getParameterName() );
    my $cooksid = $req->getCookie( $self->getCookieName() );

    if ($reqsid && $cooksid)
    {
        $self->writeLog("WARNING: requested session IDs don't match: $reqsid != $cooksid") if ($reqsid != $cooksid);
    }

    if ($reqsid)
    {
        return $self->__returnDesiredSID($reqsid, 'request');
    } elsif ($reqsid eq '0') {
        return $self->__returnDesiredSID('0', 'want-zero');
    }

	# LOCATION 3: cookie 'session'.
    if ($cooksid)
    {
        return $self->__returnDesiredSID($cooksid, 'cookie');
    } 

	return 0;   # NOTHING.
}


###### CAPTCHAS #######################################################
sub _initCaptcha
{
	my ($self) = @_;


	my $datadir = $self->getConfig("captcha-data", required => 1);
	my $outpath = $self->getConfig("captcha-path", required => 1);

	loadClass('Authen::Captcha;');
	
	my $rv;	
	eval { 
		my $captcha = Authen::Captcha->new(
   	    	data_folder => $datadir,
   	    	output_folder => $outpath,
		);
		$rv = $captcha;
	}; 
	if ($@)
	{
		$self->abort("Authen::Captcha failed to initialise: $@");
	}
	return $rv;
}

sub createCaptcha
{
	my ($self, $label, %args) = @_;

	my $captcha = $self->_initCaptcha();

	my $len = $args{length} || (5 + int(rand(3)));
	my $md5 = 0;

	my $tries=0;
	while ( (!$md5) && ($tries<50) )
	{
		++$tries;

		# this function sometimes dies if it can't do its cleanup of old files,
		# but calling again usually works...
		$md5 = $captcha->generate_code($len) ;
	}

	$self->abort("could not generate captcha") 
		if (!$md5);

	$self->put("CAPTCHA_$label", $md5);

	return $md5;
}

sub getCaptchaPath
{
	my ($self, $label) = @_;

	my $md5 = $self->get("CAPTCHA_$label") || 
		return '';

	my $base =  $self->getConfig("captcha-path-virtual");
	if (!$base)
	{
		# best guess... assume everything up to 'htdocs' is physical.
		$base =  $self->getConfig("captcha-path");
		$base =~ s#.*htdocs##;
	}
	$base .= '/' unless ($base =~ m#/$#);

	return "$base/$md5.png";
}

sub checkCaptcha	 # return 1 on success, 0 on err, negative on fail
{
	my ($self, $label, $response, %args) = @_;

	my $md5 = $self->get("CAPTCHA_$label");

	my $captcha = $self->_initCaptcha();
	my $rc = $captcha->check_code($response,$md5);

	$self->del("CAPTCHA_$label");

	return $rc;
}

sub _staticCheckSessionExpiration
# called by cleanupExpired() to examine age of an idle session on disk/database.
#
# Compare arguments idle/maxidle, and age/lifespan; if the former
# exceeds the latter in either case return 1, else return 0.
{
    my (%args) = @_;

    return 1 if ($args{maxidle} && ( $args{idle} > $args{maxidle}));
    return 1 if ($args{lifespan} && ( $args{lifespan} > $args{lifespan}));
    return 0;
}

sub __initForceCleanup
# Check request to see if SESSION_CLEANUP= (some password from config).
# If true, we'll clean up on finish(), otherwise let randomness decide.
{
    my ($self, $req) = @_;

    my $inpw = $req->get('SESSION_CLEANUP') || return 0;
    my $wantpw = $self->getConfig('cleanup-password') || return 0;

    if ($wantpw && ($inpw eq $wantpw))
    {
        $self->{_forceCleanup} = 1;
    } 
    return 0;
}

################## STATIC ###################################################

sub factoryCreate    # STATIC ( type => file|null, config => .. ) 
# returns Baldrick::Session or descendant
# Static factory method to create a session object from a config-file section.  
{
    my (%args) = @_;

    my $config = $args{config} || { };
    my $type = $args{type} || $config->{type} || 'file';

    my $classname = 'Baldrick::FileSession';
    my $rv = 0;

    if ($type eq 'none' || $type eq 'null') {
        return (new Baldrick::Session(%args, type => 'null'));
    } elsif ($type eq 'database') {
        $classname = 'Baldrick::DatabaseSession';

        unless ($args{database})
        {
            my $cr = requireArg(\%args, 'creator');
            my $dsn = $config->{database} || 
                $cr->abort("database not specified in SessionManager config");
            my $db = $cr->getDatabase($dsn) || 
                $cr->abort("cannot open database $dsn for sessions");
            $args{database} = $db;
        } 

    } elsif ($type eq 'file') {
        $classname = 'Baldrick::FileSession';
    } elsif ($type) {
        $classname = $type;
    } else {
        die("cannot create session - no type specified, label $args{label}");
    }

    $rv = createObject($classname);
    $rv->init(%args);
    return $rv;
}

1;
