
# Baldrick::Dogsbody - this should be overridden with a class that does the 
# actual work involved in processing a web hit.

# v0.1 2005/10 hucke@cynico.net
# v0.2 2006/06 moved most of new() to init(); cleanup; rename members.
# v0.7 2007/08 new template adapter setup.

package Baldrick::Dogsbody;
use strict;
use base qw(Baldrick::Turnip);

use Baldrick::Util;
use Data::Dumper;

our $DUMP_ORDINAL = 1;

sub init # ( %args )
{
	my ($self, %args) = @_;

    eval {
        $self->SUPER::init(%args, 
            copyRequired => [ qw(request app session definition) ],
            copyOptional => [  qw(config command userloader 
                default_cmd default_args cmd_parm 
                errortemplate templatedir cmdAliases
                parentHandler) ],
            copyDefaults => {
                errortemplate => 'error',
                cmdAliases => { },
            }
        ); 
    };
    if ($@)
    {
        die("Dogsbody Initialisation error: $@  (perhaps init() was called without arguments?");
    }
   
    $self->{_moduleName} = $args{module};
 
    # this can be set to 1 when processing commands to halt processing 
    # of further commands.
    $self->{_done} = 0; 
    
    $self->{_response} = $self->getRequest()->getResponse();
    
    if (my $dir = $self->getDefinitionItem('working-directory'))
    {
        chdir($dir);
    }

    if (my $lf = $self->getDefinitionItem('logfile'))
    {
        $self->openLog(file => $lf);
    } 

	my $app = $self->{_app};		

    my $out = $self->_initTemplateAdapter(app => $app, request => $self->getRequest());

	$self->{_currentUser} = new Baldrick::User();

	# if _command (part after ':' in path config file) begins
	# with '?', allow it to be overridden by user-specified command.
	if ($self->{_command} =~ m/^\?(.*)/)
	{
		my $defcmd = $1;
		my $cmd = $self->getRequest()->getParameter('cmd');
		if ($cmd)
		{
			$self->{_command} = $cmd;
		} else {
			$self->{_command} = $defcmd;
		} 
	} 

	$self->{_validator} = $args{validator} || new Baldrick::InputValidator(
		request => $self->{_request},
        creator => $self
	);
	$out->addObject( $self->{_validator}, "validator");
   
	return $self;
}

### ACCESSORS ###
sub getParentHandler    { return $_[0]->{_parentHandler}; }
sub getValidator    { return $_[0]->{_validator}; }
sub getCommand      { return $_[0]->{_currentCommand}; }
sub getCurrentUser  { return $_[0]->{_currentUser}; } 
sub getDefinition   { return $_[0]->{_definition}; }
sub getSession      { return $_[0]->{_session}; }
sub getApp          { return $_[0]->{_app}; }
sub getOut          { return $_[0]->{_out}; }
sub getRequest      { return $_[0]->{_request}; }
sub getResponse     { return $_[0]->{_response}; } 
sub getUserLoader   { return $_[0]->{_userloader}; }
sub getModuleName   { return $_[0]->{_moduleName}; }

sub getDefinitionItem   
{ 
    my ($self, $k) = @_;
    my $defs = $self->getDefinition();
    return $defs->{$k};    
}

sub getDatabase
{
    my ($self) = @_;
    my $dbname = $self->getDefinitionItem('database') || 'main';

    return ($self->getApp()->getDatabase($dbname) );
}

#############################

sub _initTemplateAdapter
{
    my ($self, %args) = @_;

    my $app = $args{app} || 0;
    my $req = requireArg(\%args, 'request');

    # find a named TemplateAdapter config section - in our config, or app's config.
    my $adapterName =  $self->getDefinitionItem('template-adapter') || 'default';
    my $cfg = $self->getConfig($adapterName, section => 'TemplateAdapter') || 
        ($app ? $app->getConfig($adapterName, section => 'TemplateAdapter') : 0);

    my $def = $self->getDefinition();
    my $tbase = $def->{'template-base'} ? $def->{'template-base'} 
        : $app ? $app->getConfig('template-base', section => 'Baldrick', defaultvalue => 'templates') 
        : 'templates';

    my $tdir = $self->{_templatedir};
    my $subs = {
        TEMPLATE_BASE => $tbase, 
        MODULE_TEMPLATES => $self->{_templatedir}, 
        DOCUMENT_ROOT => $req->getDocumentRoot(),
        SCRIPT_DIR => $req->getBaseDirectory()
    };

    my $adapter = 0; 
    if ($cfg)
    {
        $adapter = Baldrick::TemplateAdapter::factoryCreateObject(
            name => $adapterName, config => $cfg, creator => $self,
            substitutions => $subs,
        );
    } elsif ($app) {
        $adapter = $app->getDefaultTemplateAdapter(creator => $self,
            substitutions => $subs
        );
    } else {
        $adapter = Baldrick::TemplateAdapter::factoryCreateObject(
            name => 'default', config => { }, creator => $self,
            substitutions => $subs,
        );
    } 
	$self->{_out} = $adapter;

    $adapter->addObject( $self, "handler");
    $adapter->addObject( $self->getResponse(), "response");
    $adapter->addObject( $self->getRequest(), "req");
    $adapter->addObject( $self->getRequest()->getContents(), "request");
    $adapter->addObject( $self->getUserLoader(), "userloader");

    my $ssn = $self->getSession();
    $adapter->addObject( $ssn, "sess");
    $adapter->addObject( $ssn->getContents(), "session");

    return $adapter;
}

sub getCommandAliases
{
    return $_[0]->{_cmdAliases};
}

sub addCommandAlias
{
    my ($self, $left, $right) = @_;

    my $ca = $self->getCommandAliases();
    $ca->{$left} = $right;
    return $ca;
}

sub getTemplate
{
	my ($self, $filename, %args) = @_;

    # if full path specified, use it.
    return $filename if ($filename =~ m#^/# && -f $filename);   
    return $self->getOut()->findTemplate($filename, %args);
}

sub finish # ()
{
	my ($self) = @_;
	return 0 if ($self->{_finished});

    # $self->getOut()->finish();    already done in _afterRun()
    $self->SUPER::finish();
 	
	foreach my $k qw(_request _app _session _out _response)
	{
		delete $self->{$k};
	}
	$self->{_finished} = 1;
}

sub DESTROY # ()
{
	my ($self) = @_;
	$self->finish();
}

sub sendXML
{
	my ($self, %args) = @_;
	if ($args{startxml})
	{
		$self->sendOutput(ctype => 'text/xml',
			text => qq!<?xml version="1.0" encoding="utf-8"?>\n!);
	} else {
		$self->sendOutput(%args, ctype => 'text/xml');
	}
}

sub sendOutput # ( text=>(text) | template=>filename | dump => object | error => message | errorpage => message )
# required: one of:
#   text => text
#   template => relative or absolute file path
#   error => error message, to be printed as a div
#   errorpage => error message, to be printed using error template
#   dump => object 
# optional:
#   wraptag => "TAG attr=foo attr=bar" 
{
    my ($self, %args) = @_;

    my $response = $self->getResponse();
    
    $self->doHeader(%args);
    
    my $what = requireAny(\%args, 
        [ qw(error errorpage text textref dump template find_template) ]
    );
        
    my $wrapper = $args{wraptag};
    if ($wrapper)
    {
	   $response->sendText("<$wrapper>");
    } 
      
    $self->_sendOutputInner($what, %args);
    
    if ($wrapper)
    {
        $wrapper =~ s/\s+.*//;
        $response->sendText("</$wrapper>");
    }
    return 0; 
}
    
sub _sendOutputInner  # ( 'text'|'template'|..., [text => ..], [template => ..], etc.)
# the guts of sendOutput; this interpreters the various text|template|error etc. parameters
# and calls response->sendText() with the desired output.
{
	my ($self, $what, %args) = @_;

    my $response = $self->getResponse();
    
	my $contents = $args{$what};
	
    if ($what eq 'error')
    {
        $response->sendText(sprintf(qq|<div class="%s">%s</div>|, $self->{_divclass_error} || "error", $contents));	
    } elsif ($what eq 'errorpage') {
        $contents ||= $@ || 'unknown error';
        $self->getOut()->putInternal('errorMessage', $contents);

        my $fullpath = $self->getTemplate( $self->{_errortemplate} || 'error');
        if ($fullpath)
        {
            return $self->_sendOutputInner('template', %args, template => $fullpath);
        } else {
            $response->sendText(sprintf(
                qq|<h1>error</h1>\n<p>%s</p><p><i>additionally, <b>errortemplate</b> was not defined in %s 
                </i></p><hr>Baldrick Application Framework %s|, 
                    $contents, ref($self), $Baldrick::Baldrick::VERSION)
            );
        } 
	} elsif ($what eq 'dump') {
		my @caller = caller(1);
        my $ord = ++$DUMP_ORDINAL;
        my $type = ("".ref($args{dump})) || 'object';
        my $headline = $args{headline} || "$type dumped from $caller[0] $caller[2]";

        my $output = qq#<div class="webdump_head"><a onClick="javascript:var foo=document.getElementById('webdump$ord');foo.style.display=foo.style.display ? '' : 'none';">$headline</a></div>\n#;
        $output .= qq#<div id="webdump$ord" class="webdump_body">#;
		$output .= "<pre>" . Dumper($args{dump}) . "</pre>\n";
        $output .= qq#</div>#;
		$response->sendText($output);
	} elsif ($what eq 'text') {
		$response->sendText($contents);
    } elsif ($what eq 'textref') {
		$response->sendText($contents);
    } elsif ($what eq 'template' || $what eq 'find_template') {
    	my $ta = $self->getOut();
        if (my $fullpath = $ta->findTemplate($contents))
        {
		    my $outref = $ta->processFile( $fullpath );
		    $response->sendText($outref);
        } else {
            $self->fatalError($ta->getError(), uplevel => 1);
        }
	} else {
        $response->sendText('ERROR: sendOutput() called without valid parameters');   
        return -1;
    } 
 
    return 0;
}

sub _resolveCommandAlias
{
    my ($self, $cmdArgs) = @_;

    my $ca = $self->getCommandAliases() || return -1;
    my $cmd = $cmdArgs->{cmd};
    if (defined($ca->{$cmd}))
    {
        my $newcmd = $ca->{$cmd};
		if ($newcmd =~ m/^([^:]+):(.*)/)
        {
            $cmdArgs->{cmd} = $1;
            $cmdArgs->{cmdargs} ||= $2;
        } else {
            $cmdArgs->{cmd} = $newcmd;
        } 
    } 
    return 0;
}

sub processRequest # (%args)
# Main entry point.  Will grab list of commands from CGI (usually in 'cmd'
# variable), then call the handler for each.
{
	my ($self, %args) = @_;

	return 0 if ($self->{_done});

    my $def = $self->getDefinition();
    my @cmdlist = $self->getCommandList();

	eval {
        $self->_prepareRun(commandlist => \@cmdlist);

		if ($#cmdlist < 0)
		{
			if ($self->{_default_cmd} )
			{
				my %temp = ( 
					cmd => $self->{_default_cmd}, 
					cmdargs => $self->{_default_args},
				);
				push (@cmdlist, \%temp);
			} else {
				return $self->handleDefaultCommand( cmd => 'DEFAULT', args => "" );
			}
		} 
	
		for (my $c=0; ($c<=$#cmdlist) && (! $self->{_done} ); $c++)
		{
            my $cmd = $cmdlist[$c]->{cmd};
			my %argsForCmd = (
				cmd => $cmd,
				cmdargs => $cmdlist[$c]->{cmdargs},
				cmdcount => 1+ $#cmdlist,
				cmdindex => $c,
				last => ($c == $#cmdlist) ? 1 : 0,
				cmdlist => \@cmdlist
			);

            $self->_resolveCommandAlias(\%argsForCmd);

			if ($c == 0)
			{
				$self->beginRun(%argsForCmd);
			} 

            $self->writeLog("handling command '$cmd'");
            if (my $ct= $def->{"command-trace"})
            {
                if ($ct eq 'user')
                {
                    $self->sendOutput(text => "<li>command trace: cmd=$argsForCmd{cmd}</li>");
                } 
                
            } 

			$self->dispatchCommand ( %argsForCmd ) unless ($self->{_done});

            $self->mutter("after command $argsForCmd{cmd}");

			if ( $self->{_done} || ($c == $#cmdlist))
			{
				$self->endRun(%argsForCmd);
			} 
		}
        $self->_afterRun();
	};
	if ($@)
	{
		$self->abort($@);
	} 

	return 0;
}

sub checkModuleAccess		# return 0 if OK else error code.
{
	my ($self) = @_;

	my $def = $self->getDefinition();

	my $access = $def->{access};
	return 0 if (!$access);

	my $user = $self->getCurrentUser();

	foreach my $word (split(/\s+/, $access))
	{
		return 0 if (($word eq 'anonymous') && (! $user->isLoggedIn()) );
		return 0 if (($word eq 'valid-user') && $user->isLoggedIn() );
		return 0 if ($word eq 'all');

		# if starts with '!' then access is forbidden to this group, 
		# even if they'd be let in otherwise.

		my $inverting=0;

		if ($word =~ m/^!(.*)/)
		{
			$word=$1;
			$inverting=1;
		}  

		# based on arbitrary user characteristic "[" field=value "]"
		if ($word =~ m#^\[(.*)=(.*)\]#)
		{
			my $key = $1;
			my $val = $2;

			if ($user->{$key} eq $val)
			{
				return $inverting ?  'FORBIDDEN' : 0;
			} 
		} elsif ($word) { 
			if ($user->getGroup($1))
			{
				return $inverting ?  'FORBIDDEN' : 0;
			} 
		} 
	} 

	return 'NOACCESS';	# more complex return codes later?
}

sub loadCurrentUser
{
	my ($self) = @_;
    
   	my $user = $self->{_userloader}->loadCurrentUser (
       	session => $self->getSession(),
		request => $self->getRequest()
	);
    
	if (! $user)
	{
		$user = new Baldrick::User();
	}
	$self->{_currentUser} = $user;
	$self->getOut()->addObject($user, "user");
	return $user;
}

sub doHeader
{
    my ($self, %args) = @_;
    return $self->getResponse->doHeader(%args);
}

sub addResponseHeader
{
    my ($self, %args) = @_;
    deprecated("dogsbody.addResponseHeader() should be response.addResponseHeader()");
    return $self->getResponse()->addResponseHeader(%args);
}

sub initStandardResponseHeaders
# Add the Session header, and any headers defined in the module definition, to the Response.
{
    my ($self) = @_;

    my $resp = $self->getResponse();
    $resp->addResponseHeader(fullheader => $self->getSession()->getHeader());
    
    my $def = $self->getDefinition();
   
    # Now copy headers from responseheader-* in the definition.
    # (order is random, for now...)
    foreach my $k (keys %$def)
    {
        if (0== index($k, "responseheader-"))
        {
            $resp->addResponseHeader(fullheader => $def->{$k});
        } 
    } 

    return 0;
}

sub _prepareRun
# This is the first phase of dealing with a client request. 
# Initialises output headers and loads user.
# May be overridden if desired, but subclass should call parent's _prepareRun().
{
	my ($self, %args) = @_;

    my $req = $self->getRequest();
    my $logprefix = $req->getRemoteIP();

    # initialise HTTP headers including Session cookie.
    $self->initStandardResponseHeaders();

	# load current user, and react appropriately to any login errors.
	if (my $ul = $self->{_userloader})
	{
		my $user = $self->loadCurrentUser();

		if (my $err = $ul->getLoginError())
		{
			return $self->fatalError($err);
		}

        if ($user->isLoggedIn())
        {
            my $nomen = $user->{username} || $user->{email} || $user->{userid};
            $logprefix .= "/" . $nomen;
        }
	}

	if (my $accessfail = $self->checkModuleAccess())
	{
		$self->errorAccessFailure(%args, failuretype => $accessfail);
		return -1;
	}

    $self->{_logprefix} = "[$logprefix]";
	return 0;
}

# beginRun and endRun: these are run before the first command
# and after the last command, with the same arguments as the
# first/last commands in the list.  They should be used for
# setup/cleanup if needed.  
sub beginRun { return 0; }

sub endRun { return 0; }

sub _afterRun
# Do final cleanup at end of request, including writing out changes to the session file.
{
	my ($self)= @_;

    my $ssn = $self->getSession();

    my $def = $self->getDefinition();
    if (my $counter = $def->{'session-page-counter'})
    {
        $ssn->put($counter, 1+  $ssn->get($counter, defaultvalue => 0));
        $self->getSession()->finish();
    }
    
    # WRITE OUT CHANGES TO SESSION - VERY IMPORTANT. 
    $ssn->finish();

	if (! $self->getResponse()->didOutput() )
	{
		my $cgi = $self->getRequest()->getParameters();
		$self->sendOutput(error => 
			"Processing of command \"$cgi->{cmd}\" terminated without generating any output.");
	} 

	return 0;
}

sub errorAccessFailure
# Take any of several actions when permission to use this module is denied; this could be 
# a page, a redirect, or defenestration.
{
	my ($self, %args) = @_;

	my $action = $self->getDefinition()->{'access-failure-action'};
	my $message = $self->getDefinition()->{'access-failure-message'} || 
		"Sorry, you don't have permission to use this module.  Perhaps you need to log in.";

	$self->getOut()->putInternal("errorMessage", $message);

	my ($cmd, $cmdarg) = split(/\s+/, $action);
	if ($cmd eq 'redirect' && $cmdarg)
	{
		$self->doRedirect($cmdarg);			
	} elsif ($cmd eq 'template' && $cmdarg) {
		$self->sendOutput(template => $cmdarg);	
	} elsif ($cmd) {
		$cmd =~ s/[^a-z0-9-_]//g;
		$self->dispatchCommand(cmd => $cmd, args => $cmdarg, cmdlist => [ $cmd ], 
			cmdcount => 1, cmdindex => 0);	
	} else {
		 $self->fatalError($message);
	} 
	$self->{_done} = 1;
	return 0;
}

sub doRedirect
{
	my ($self, $where, %args) = @_;
    $self->getResponse()->doRedirect($where, %args, session => $self->getSession());
}

sub dispatchCommand # ( %args) 
# Command dispatcher.  Transmogrifies user-provided command such as
# 'add-to-cart' into function name handleAddToCart() and calls that method.  
# opt cmd => command to execute, only alphanum, '_', '-' acceptable.
# opt args => optional argument to that command.
# opt cmdlist => LISTREF
# opt cmdcount => size of cmdlist
# opt cmdindex => index into cmdlist
{
	my ($self, %args) = @_;
	my $class = ref($self);
   
	my $cmd = $args{cmd};	# command (without arg) that came from CGI
	$self->{_currentCommand} = $cmd;

    my $command = $self->_transformCommand($cmd);
    my %cmdBundle = (
        %args,  # cmd, cmdlist, cmdcount, etc. 
        O => $self->getOut(),
        P => $self->getRequest()->getContents(),
        Q => $self->getRequest(),
        R => $self->getResponse(), 
        U => $self->getCurrentUser(),
        command => $command
    );
    
	if (! $command)
	{
        return $self->handleDefaultCommand(%cmdBundle);
	}

    my $fname = 'handle' . $command;
    $cmdBundle{functionName} = $fname;
    
    my $coderef = $self->can($fname);
    if (!$coderef)
    {
	    return $self->handleUnknownCommand(%cmdBundle);
    } 

    my $rv = -1;
    eval {
        # no strict 'refs';
        # $rv = $self->$fname;
        $rv = &$coderef($self, %cmdBundle);
    };
	if ($@)
	{
		# Can't locate object method "handleFred" via package 
		# "Baldrick::Dogsbody" at (eval 19) line 1.
		my $err = $@;
		if ( $err =~ m/locate object method "$fname"/)
		{
			return $self->handleUnknownCommand(%cmdBundle);
		} else {
			return $self->setError($@, fatal => 1, no_stderr => 1);
		}
	}
	return $rv;
}

sub _transformCommand # ($cmd)
# return command transformed into partial function name (caller should
# add 'handle' prefix).
# ex. codpiece => Codpiece
# ex. add-to-cart => AddToCart
# ex. ^*# => exception
{
	my ($self, $cmd) = @_;

	# $cmd =~ tr/A-Z/a-z/;	# lowercase it.

	# untaint it.
	if ($cmd =~ m/^([A-Za-z0-9-_]+)/)	# strip all but a-z, -, _
	{
		$cmd=$1;
	} else {
		$self->setError("unacceptable command syntax '$cmd'", fatal => 1);
	} 

	# Now convert to partial function name.
	my $upper = ord('A') - ord('a');
	my $capstate = 1;	# initial cap.

	# copy it into $rv letter-by-letter; with a _ or - being skipped but causing next letter to be caps.
	my $rv = '';
	my $lim = length($cmd);
	for (my $i=0; $i<$lim; $i++)
	{
		my $ch = substr($cmd, $i, 1);
		if ($ch eq '-' || $ch eq '_')
		{
			$capstate=1;
		} else {
			if ($capstate > 0)
			{
				if ( (ord($ch) >= ord('0')) && (ord($ch)<=ord('9')))
				{
					# digit - use as-is.
					$rv .= $ch;
				} elsif ( (ord($ch) >= ord('A')) && (ord($ch)<=ord('Z'))) {
					# already cap, copy as-is
					$rv .= chr( ord($ch) + $upper);
				} elsif ( (ord($ch) >= ord('a')) && (ord($ch)<=ord('z'))) {
					# letter - ucase it.
					$rv .= chr( ord($ch) + $upper);
				} 
				$capstate=0;
			} else {
				$rv .= $ch;
			}
		}
	} 

	# This is for loop prevention.
	$rv = '' if ($rv eq 'DefaultCommand');
	$rv = '' if ($rv eq 'UnknownCommand');
	return ($rv);
}

sub handleUnknownCommand # ( func => handleXXX, cmd => XXX, ...)
# This is called when 'cmd' is gibberish (doesn't map to a handleXXX function).
#
# By default this calls setError and throws an exception; you may wish
# to override to give a different error message or to do something useful.
{
	my ($self, %args) = @_;

	$self->abort(
        sprintf("Sorry, I don't know how to '%s'.",
            $args{command} || $args{cmd} || $args{functionName} || "do that"),
        privmsg => sprintf(
            "Cannot locate handler %s->%s() for command '%s'",
        ref($self), $args{functionName} || 'ERR-UNKN-FUNC', $args{cmd})
    );
}

sub handleDefaultCommand
{
	my ($self, %args) = @_;

	$self->abort("No default command was defined.");
}

sub handleDummy
# This is for handling dummy requests, like the ones Apache generates
# to itself, or Nagios monitoring plugins.  It can be invoked as a 
# function of _INTERNAL_ by a UserAgent
{
    my ($self, %args) = @_;
    $self->sendOutput(text => sprintf( "OK\n<br>\n\n<br>\n%s\n<br>\nBaldrick v%s<br>\n", $self->getRequest()->getServerName(), $Baldrick::Baldrick::VERSION)
    );
}

sub getCommandList # () return LIST of { cmd=> ..., cmdargs => ... }
# given cgi input containing cmd => [ cmd0 [:arg0] [ | cmd1[:arg1] ] ]
# split into list of commands and optional arguments.
{
	my ($self) = @_;

	my $req = $self->getRequest();
	my $parm = $self->{_cmd_parm} || 'cmd';
	my $cmdlist = $self->{_command} || $req->getParameter($parm);

	my @rv;
	my @clist = split (/\|/, $cmdlist);
	
	for (my $i=0; $i<=$#clist; $i++)
	{
		my $longcmd = $clist[$i];
		my %parsed = (
			cmd => $longcmd,
			cmdargs => '',
		);
		if ($longcmd =~ m/^([^:]+):(.*)/)
		{
			$parsed{cmd} = $1;
			$parsed{cmdargs} = $2;
		}
		push (@rv, \%parsed);
	}
	return @rv;
}

sub abort
# deprecated wrapper for fatalError()
{
	my ($self, $msg, %args) = @_;
	$args{uplevel}++;
    return $self->fatalError($msg, %args);
}

sub fatalError
# no_output - don't generate error page (assume it's been done already), just do the
#    logfile and termination stuff.
{
	my ($self, $msg, %args) = @_;

	return 0 if ($self->{_DID_ABORT});  # this prevents loops if there's a problem with template handling.
	$self->{_DID_ABORT} = 1;

    unless ($args{no_output})
    {
        eval {
            $self->sendOutput(errorpage => $msg);
    	};
    	if ($@)
    	{
    		$self->sendOutput(text => "<p><h2>error:</h2> <p>$msg</p>\n");
		    $self->sendOutput(text => "<p><b>additional error processing error template:</b> $@</p>\n");
	    }
    }

	$args{uplevel}++;
    $@='';
	Baldrick::Turnip::fatalError($self, $msg, %args); 
}

sub setError
{
	my ($self, $msg, %args) = @_;
	if ($args{fatal})
	{
		$self->doHeader();
	} 

	$args{uplevel} ||= 0;
    $args{uplevel} += 1;
    if ($args{critical})
    {
        $args{notify_mail} ||= 
            $self->getDefinitionItem('errornotify') || 
            $self->getApp()->getConfig("site-admin-email");
    } 
	Baldrick::Turnip::setError($self, $msg, %args);
}

sub handleNoModuleDefinedError
{
	my ($self, %args) = @_;

	my $req = $self->getRequest();
	my $path = $req->getPath();

	$self->sendOutput(text => "<h2>Baldrick: No module configured at address '$path'.  You need to edit the 'PathMap' section in baldrick.cfg.</h2>\n");

	return 0;
}

sub getConfig
# Enhances normal getConfig() with twiddle-eval functionality;
# if config option value begins with ~xx:, run the rest of it thru
# the template processor specified with 'xx'.
{
	my ($self, $cfgkey, %args) = @_;

	my $rv = Baldrick::Turnip::getConfig($self, $cfgkey, %args);
	if ('~' eq substr($rv,0,1))
	{
		# ~ADAPTER:EXPRESSION
		if ($rv =~ m/^\~([a-z]+):(.*)/) 
		{
			my $evaluator = $1;
			my $expr = $2;

			return $self->getOut($evaluator)->processString($expr);
		} else {
			return $rv;
		}
	} else {
		return $rv;
	}
}

sub writeLog
{
	my ($self, @stuff) = @_;

	my $req = $self->getRequest();
	my $lp = sprintf("[%s]", $req->getRemoteIP());

    if ($self->{_logToUser})
    {
        $self->sendOutput(
            text => qq!<span class="baldrick_log_user">! . $stuff[0] . "</span><br>");
    } 
	return Baldrick::Turnip::writeLog($self, @stuff, logprefix => $lp);
}

sub sendToModule
{
    my ($self, %args) = @_;

    my $rv = $self->getApp()->sendToModule(
        parentHandler => $self, 
        %args 
    );
    
    return $rv;
}
1;
__END__
=head1 NAME

Baldrick::Dogsbody - base class for request handlers

=head1 SYNOPSIS

    use base qw(Baldrick::Dogsbody)

=head1 DESCRIPTION

    In the Baldrick Application Framework (http://www.baldrickframework.org/), 
    a "Dogsbody" is a request handler.  It services exactly one user request, and is 
    then destroyed.
    
    Module authors should create classes that inherit from Baldrick::Dogsbody, to 
    provide the controller logic for their application.
    
=head1 SEE ALSO

    Baldrick::Examples::ExampleDogsbody
    http://www.baldrickframework.org/book/Dogsbody
    
=head1 AUTHOR

    Matt Hucke, hucke at cynico dot net
    
=cut
