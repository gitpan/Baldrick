
package Baldrick::InputValidator;

# InputValidator 1.0 
# Provides functions for validating a user's input (CGI parameters, usually)
# and for storing the error messages.
# 
# 1.0 2007/01/21
# 1.1 2007/09/14 - added validate() function

use Baldrick::Turnip;
use Baldrick::Util;
use strict;

our @ISA = qw(Baldrick::Turnip);
our $REGEX_DATE = '^[12]\d\d\d-[01]?\d-[0123]?\d';
our $REGEX_TIME = '^[012]*\d:[012345]\d(:\d*\d\.?\d*)?';

sub init
{
	my ($self, %args) = @_;

	$self->{_errorInfo} = { };

    $self->SUPER::init(%args, 
        copyDefaults => {   
            request => 0, 
            format_engine => 0,
            parms => 0, 
            config => {}, 
            friendlyPrefix => 'your', 
            publicNames => {}, 
            errorformat => qq|<br><span class="error">%s</span>|, 
        }
    );

	# FIX ME: implement this - if 2nd error for same field append messages.
#	$self->{_mergeerrors} = 1 unless ($args{no_merge_errors});
	
	return $self;
}

sub setCustomErrorMessages { $_[0]->{_customErrs} = $1; }
sub getCustomErrorMessages { return $_[0]->{_customErrs}; }

sub validate
# Validate a set of inputs based on a config-file section.  Use text rules to
# call checkPresent, checkLength, etc.
{
    my ($self, %args) = @_;

    my $rs = requireArg(\%args, 'ruleset');

    my $ruleset = $self->getConfig($rs, section => 'RuleSet', 
        required => 1);

    my $fields = $self->getConfig('Fields', config => $ruleset,
        required => 1);

    my $fieldlist = $self->getConfig('fieldlist', config => $ruleset,
        aslist => 1);

    $fieldlist = [ keys %$fields ] if (!$fieldlist || $#$fieldlist<0); 

    my $pnOld = $self->{_publicNames};
    my $emOld = $self->getCustomErrorMessages();

    if (my $pn = $self->getConfig('public-name-set', config => $ruleset,
                    defaultvalue => $rs)
    )
    {
        my $pnset = $self->getConfig($pn, section => 'PublicNameSet');
        $self->{_publicNames} = $pnset if ($pnset);
    }

    if (my $em = $self->getConfig('ErrorMessages', config => $ruleset))
    {
        $self->setCustomErrorMessages($em);
    } 

    foreach my $field (@$fieldlist)
    {
        if ($self->validateField($field, %args, rules => $fields->{$field}))
        {
            $self->writeLog(sprintf("field %s (value='%s') fails validation with ruleset %s, rules '%s'",
                $field, $self->_getInputValue($field, %args), $rs, $fields->{$field}
            ));
        } 
    }

    $self->{_publicNames} = $pnOld;
    $self->setCustomErrorMessages($emOld);

    return $self->errorCount();
}

sub validateField
{
    my ($self, $field, %args) = @_;

    my @rules = split(/\s*;\s*/, requireArg(\%args, 'rules'));
    my $errs = 0;

    my $value = $self->_getInputValue($field, %args);

    foreach my $r (@rules)
    {
        my $op = $r;
        my @ruleArgs;

        if ($r =~ m/(.*)\((.*)\)/)
        {
            $op = $1; 
            @ruleArgs = split(m/,\s*/, $2);
        } 
    
        if ($op eq 'bypass')
        {   
            foreach my $expr (@ruleArgs)
            {
                if ($value =~ m/$expr/)
                {
                    # NO MORE PROCESSING IF IT MATCHES.
                    $self->mutter("field '$field' value '$value' rule '$r' bypass match");
                    return 0;
                } else {
                    $self->mutter("field '$field' value '$value' rule '$r' bypass no-match");
                }
            } 
        } else {
            my $rc = 
                ($op eq 'required')     ? $self->checkPresent($field, %args, rulename => $op) : 
                ($op eq 'integer')      ? $self->checkInteger($field, %args, rulename => $op) :
                ($op eq 'numeric')      ? $self->checkNumeric($field, %args, rulename => $op) :
                ($op eq 'email')        ? $self->checkValidEmail($field, %args, rulename => $op) :
                ($op eq 'length')       ? $self->checkLength($field, %args, rulename => $op,
                                          min => $ruleArgs[0], max => $ruleArgs[1]) : 
                ($op eq 'range')        ? $self->checkValueInRange($field, %args, rulename => $op,
                                          min => $ruleArgs[0], max => $ruleArgs[1]) : 
                ($op eq 'equals-field') ? $self->checkEqualsField($field, %args, rulename => $op, 
                                          otherfield => $ruleArgs[0]) :
                ($op eq 'equals-value') ? $self->checkEqualsValue($field, %args, rulename => $op,
                                          goodvalue => $ruleArgs[0]) :
                ($op eq 'matches')      ? $self->checkMatches($field, %args, rulename => $op,
                                          pattern => $ruleArgs[0]) :
                ($op eq 'date')      ? $self->checkMatches($field, %args, rulename => $op,
                                          pattern => $REGEX_DATE) :
                ($op eq 'time')      ? $self->checkMatches($field, %args, rulename => $op,
                                          pattern => $REGEX_TIME) :
                ($op eq 'creditcard')   ? $self->checkCreditCard($field, %args, rulename => $op) : 
                $self->setError(
                    "unknown validation operation '$op' for $field, ruleset $args{ruleset}");

            $self->mutter("field '$field' value '$value' rule '$r' returned '$rc'");
            if ($rc)
            {
                # $errs++;
                return 1;
            } 
        }
    } 
    return 0;
}

sub errorCount  # () return # of errors
{
	my ($self) = @_;
	my $errs = $self->{_errorInfo} || {};
	my @ekeys = keys (%$errs);
	return 1+ ($#ekeys);
}

sub getAllErrorInfo # return errorInfo hash
{
	my ($self) = @_;
	return $self->{_errorInfo};
}

sub getAllErrorMessages	#  ( [list=>1] )
# return HASHREF (default) or LIST.
{
	my ($self, %args) = @_;
	my $ei = $self->{_errorInfo};

	my %outhash;
	my @outlist;
	foreach my $k (keys %$ei)
	{
		$outhash{$k} = $ei->{$k}->{message};
		push (@outlist, $ei->{$k}->{message});
	}
	return @outlist if ($args{list}) ; 
	return \%outhash;
}

sub getErrorInfo
# get error object for one field, else 0.
{
	my ($self, $fn) = @_;
	
	my $errs = $self->{_errorInfo} || {};
	if (defined ($errs->{$fn}))
	{
		return $errs->{$fn};
	} else {
		return 0;
	}
}

sub getUnseenErrors  # ( [list => 0|1])
{
    my ($self, %args) = @_;

    my %out;
    my $errs = $self->getAllErrorInfo();
    foreach my $fn (keys %$errs)
    {
        my $ei = $errs->{$fn};
        next if ($ei->{showedError});
        
        $out{$fn} = $self->showError($fn);
    } 

    return $args{list} ? [ values(%out) ] : \%out;
}

sub showError	# ($fieldname)
# Format an error message appropriately (probably as HTML) and return it.
# Return null-string if no error for this fieldname.
# sample usage (in template:) 
#		<input name="username"> [% validator.showError('username') %]
{
	my ($self, $fn) = @_;	
	my $einfo = $self->getErrorInfo($fn);
	return '' if (! $einfo);

    $einfo->{showedError}++;    

	my $outtemplate = $self->{_errorformat};
	my $tt = $self->{_format_engine};
	if ($tt)
	{
		$tt->addObject($einfo, "errorinfo");
		my $rv = $tt->processString($outtemplate);
		$tt->removeObject("errorinfo");
		return $rv;
	} else {
		return sprintf($outtemplate, $einfo->{message});
	}
}

sub pushError   # ($fieldname, value => .., message => .., code => Exxx)
{
	my ($self, $fieldname, %args) = @_;
    
	my $einfo = {
		fieldname => $fieldname,
		value => defined ($args{value}) ? $args{value} : $self->_getInputValue($fieldname, %args), 
		message => $args{message} || $args{defaultmessage} || 
			sprintf("The contents of field '%s' are invalid", $fieldname),
		code => $args{code} || 'ESPECIAL'
	};

    # If using a config file with a ErrorMessages section...
    if (my $econf = $self->getCustomErrorMessages())
    {
        my $ekey = "$fieldname.$args{rulename}";
        if ($econf->{$ekey})
        {
            $einfo->{message} = $econf->{$ekey};
        } elsif ($econf->{$fieldname}) {
            $einfo->{message} = $econf->{$fieldname};
        } 
    }

    $self->writeLog("field $fieldname (value '$einfo->{value}') fails validation ($einfo->{code}): $einfo->{message}");

    unless ($args{dontsave})
    {
	    my $errs = $self->{_errorInfo};
    	$errs->{$fieldname} = $einfo;
    }
	return $einfo;
}

sub setSource
{
    my ($self, $foo) = @_;
    $self->{_sourceValues} = $foo;
}

sub _modifyInputValue
{
    my ($self, $fn, $val, %args) = @_;

    $self->mutter("changing source value of '$fn' to '$val'");

	if (defined ($args{truefieldname}))
	{
		$fn = $args{truefieldname} 	
	}

	if ($self->{_sourceValues} ) 
    {
		$self->{_sourceValues}->{$fn} = $val;
    } elsif (defined ($args{request})) {
		$args{request}->put($fn, $val);
	} elsif (defined ($args{parms}) ) {
		$args{parms}->{$fn} = $val;
	} elsif ($self->{_request}) {
		$self->{_request}->put($fn, $val);
	} else {
		# shouldn't happen.
		$self->abort("cannot find input parameter object in _request or _sourceValues");
	} 
}

sub _getInputValue # ( $fn, [value=> ..], [ request => ... ], [ parms => {} ] )
# Look for the user's input in a variety of places, in this order:
# explicitly specified place (not commonly used)
#   args{value} = input-value
#   args{request} = Baldrick::Request object
#   args{parms} = hashref.
# the more usual cases:
#   self{_request} = cached request object -- this is the usual case.
#   self{_sourceValues} = cashed parameter hashref.
# Look it up by the fieldname specified, unless this is present:
# truefieldname => label
{
	my ($self, $fn, %args) = @_;

	# use explicit value if provided
	return $args{value} if (defined ($args{value}) );

	# or look it up in any of several objects or hashes.
	if (defined ($args{truefieldname}))
	{
		$fn = $args{truefieldname} 	
	}

	if (defined ($args{request}))
	{
		return $args{request}->get($fn, defaultvalue => undef);
	} elsif (defined ($args{parms}) ) {
		return $args{parms}->{$fn};

	} elsif ($self->{_request}) {
		return $self->{_request}->get($fn, defaultvalue => undef);
	} elsif ($self->{_sourceValues} ) {
		return $self->{_sourceValues}->{$fn};
	} else {
		# shouldn't happen.
		$self->abort("cannot find input parameter object in _request or _sourceValues");
	} 
}

sub checkValidEmail
{
	my ($self, $fn, %args) = @_;

	my $val = $self->_getInputValue($fn, %args);

	return 0 if (! $val);	## NULL IS ALWAYS OK.
	return 0 if (Baldrick::Util::validEmail($val));

	return $self->pushError( $fn, value => $val, 
		defaultmessage => sprintf("%s does not contain a valid email address; an email address should be in the form username\@domainname",
			$self->getPublicName($fn, %args)), 
		code => 'EEMAIL', 
		%args
	);
}

sub checkPresent # ($field)
# Verify that a field is present and of non-zero length.
{
	my ($self, $fn, %args) = @_;

	my $val = $self->_getInputValue($fn, %args);

	return 0 if ($val);

	return $self->pushError( $fn, value => $val, 
		defaultmessage => sprintf("please enter %s",
			$self->getPublicName($fn, %args)), 
		code => 'ENULL', 
		%args
	);
}

sub checkNumeric # ($fn)
{
    my ($self, $fn, %args) = @_;
	my $val = $self->_getInputValue($fn, %args);

	return 0 if (! $val);	## NULL IS ALWAYS OK.
    return 0 if ($val =~ m/^[0-9\.-]+$/);   

	return $self->pushError( $fn, value => $val, 
		defaultmessage => sprintf("%s must be numeric",
			$self->getPublicName($fn, %args)), 
		code => 'ENOTNUM', 
		%args
	);
}

sub checkInteger
{
    my ($self, $fn, %args) = @_;
	my $val = $self->_getInputValue($fn, %args);

	return 0 if (! $val);	## NULL IS ALWAYS OK.
    return 0 if ($val =~ m/^[0-9-]+$/);   

	return $self->pushError( $fn, value => $val, 
		defaultmessage => sprintf("%s must be a whole number",
			$self->getPublicName($fn, %args)
        ), 
		code => 'ENOTINT', 
		%args
	);
}

sub checkEqualsValue # ( $fn, goodvalue => ... )
{
	my ($self, $fn, %args) = @_;

	my $val = $self->_getInputValue($fn, %args);

	my $reqval = $args{goodvalue}; 

	return 0 if (! $val);	## NULL IS ALWAYS OK.
	return 0 if ($reqval eq $val);

	return $self->pushError( $fn, value => $val, 
		defaultmessage => sprintf("%s did not match the required value",
			$self->getPublicName($fn, %args)), 
		code => 'EEVAL', 
		%args
	);
}

sub checkMatches
{
    my ($self, $fn, %args) = @_;

	my $val = $self->_getInputValue($fn, %args);
    my $expr = requireArg(\%args, 'pattern');

	return 0 if (! $val);	## NULL IS ALWAYS OK.
    return 0 if ($val =~ m/$expr/);

	return $self->pushError( $fn, value => $val, 
		defaultmessage => sprintf(
			"%s doesn't match the pattern",
			$self->getPublicName($fn, %args), 
        ),
		code => 'EMATCH', 
		%args
	);
}

sub checkEqualsField # ( $fn, otherfield => ... )
{
	my ($self, $fn, %args) = @_;

	my $val = $self->_getInputValue($fn, %args);

	return 0 if (! $val);	## NULL IS ALWAYS OK.

	my $of = requireArg(\%args, 'otherfield');
	my $reqval = $self->_getInputValue($of);

	return 0 if ($reqval eq $val);

	return $self->pushError( $fn, value => $val, 
		defaultmessage => sprintf(
			"%s and %s must have the same contents",
			$self->getPublicName($fn, %args), 
			$self->getPublicName($args{otherfield}, %args, pnlabel => 'otherpublicname'), 
        ),
		code => 'EEFIELD', 
		%args
	);
}

sub checkValueInRange # ($fn, min => -1 | 0 | ..., max => -1 | 0 | ... )
{
	my ($self, $fn, %args) = @_;

	my $val = $self->_getInputValue($fn, %args);
    return 0 if ($val eq undef);

	if (defined ($args{min})  && ($args{min} ne '') )
	{
		if ($val < 	$args{min})
		{
			return $self->pushError( $fn, value => $val, 
				defaultmessage => sprintf(
					"%s must be at least %s", 
					$self->getPublicName($fn, %args), $args{min}), 
				code => 'ELOW', 
				%args, 
				message => $args{message_toolow} || $args{message}, 
			);
		} 
	} 

	if (defined ($args{max})  && ($args{max} ne '') )
	{
		if ($val > 	$args{max})
		{
			return $self->pushError( $fn, value => $val, 
				defaultmessage => sprintf(
					"%s must be no more than %s",
					$self->getPublicName($fn, %args), $args{max}), 
				code => 'ELONG', 
				%args, 
				message => $args{message_toohigh} || $args{message}, 
			);
		} 
	} 
    return 0;
}

sub checkCreditCard
{
    my ($self, $fn, %args) = @_;

	my $val = $self->_getInputValue($fn, %args) || return 0;

    my $ignore = $args{ignore};
    if ($ignore)
    {
        return 0 if ($val =~ m/^$ignore/);
    } 

    my $len = length($val);
    if ($len >= 12 && $len <=20)
    {
        my $sum=0; 
        my $mul=1;
        for (my $i=0; $i<$len; $i++)
        {
            my $d = substr($val, $len-$i-1, 1);
            my $tmp = $d * $mul;
            if ($tmp >= 10)
            {
                $sum += ($tmp%10)+1;
            } else {
                $sum += $tmp;
            }
     
            if ($mul==1)
            {
                $mul++;
            } else {
                $mul--;
            }
        }
        return 0 if (($sum % 10) == 0); # HAPPY.
        $self->writeLog("credit card validation failed for '$val': sum is $sum");
    }

	return $self->pushError( $fn, value => $val, 
			defaultmessage => sprintf(
				"This does not appear to be a valid credit card number.",
				$self->getPublicName($fn, %args)
            ), 
			code => 'ECRED', 
    );
}


sub checkLength # ($fn, min => -1 | 0 | ..., max => -1 | 0 | ... )
{
	my ($self, $fn, %args) = @_;

	my $val = $self->_getInputValue($fn, %args) || return 0;
	my $len = length($val);

	if (defined ($args{min}) && ($args{min}>=0))
	{
		if ($len < 	$args{min})
		{
			return $self->pushError( $fn, value => $val, 
				defaultmessage => sprintf(
					"%s must be at least %d characters",
					$self->getPublicName($fn, %args), $args{min}), 
				code => 'ESHORT', 
				%args, 
				message => $args{message_tooshort} || $args{message}, 
			);
		} 
	} 

	if (defined ($args{max})  && ($args{max}>=0))
	{
		if ($len > 	$args{max})
		{
            if ($args{fix})
            {
                $self->_modifyInputValue($fn, substr($val, 0, $args{max}));
                return 0;
            } 

			return $self->pushError( $fn, value => $val, 
				defaultmessage => sprintf(
					"%s must be no more than %d characters in length",
					$self->getPublicName($fn, %args), $args{max}), 
				code => 'ELONG', 
				%args, 
				message => $args{message_toolong} || $args{message}, 
			);
		} 
	} 
    return 0;
}

sub getPublicName   # ($fn, publicname => foo, pnlabel => publicname|otherpublicname)
{
    my ($self, $fn, %args) = @_;

    # allow lookup of 'otherpublicname' for checkEqualsField
    my $label = $args{pnlabel} || 'publicname';

    # look for explicit 'publicname=Something Here' in args.
    my $rv = $args{$label};

    if (!$rv)
    {
        my $pnames = $self->{_publicNames};
        if ($pnames && $pnames->{$fn})
        {
            $rv = $pnames->{$fn};
        } 
    }

    $rv = $fn if (!$rv);
   
    return ($self->{_friendlyPrefix} ? $self->{_friendlyPrefix} . " " . $rv : "'$rv'");
}

1;
