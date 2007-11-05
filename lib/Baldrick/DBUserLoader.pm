
# Accesses to user database are made through this factory class; this separates
# the method of storing the data from the Baldrick::User class that encapsulates it.
# 
# This also handles interpretering the config file's user section.
# 

package Baldrick::DBUserLoader;

use Baldrick::Turnip;
use Baldrick::Util;
use Baldrick::UserLoader;

use MIME::Base64;
use Data::Dumper;		
use strict;

our @ISA = qw(Baldrick::UserLoader Baldrick::Turnip);

sub init # (%args)
# args:
#	dsn => data source name (default 'main') OPTIONAL
# either of:		REQUIRED
#	database => Baldrick::Database object
#	app => Baldrick::App object
{
	my ($self, %args) = @_;

	# call upon base class init() which sets config and configbranch
	$self->SUPER::init(%args);
	requireAny(\%args, [ qw(app database) ] );

	$self->{_dsn} = $args{dsn} || $self->getConfig(
			"database", defaultvalue => 'main');

	if ($args{database})
	{
		$self->{_database} = $args{database};
		$self->{_dsn} = $self->{_database}->getName();
	} elsif ($args{app}) {
		$self->{_database} = $args{app}->getDatabase( $self->{_dsn} );
	} 

	# config setting _defaultkey is used by default by several operations
	# that want to load supplemental info (groups, addresses); of the
	# many unique identifiers a user may have, which is most often used
	# for joining?  Defaults to 'userid'.  Easily overridden by those that
	# want to join on some arbitrary field.
	$self->{_defaultkey} = $self->getConfig("defaultkey", defaultvalue => 'userid');

	return $self;
}

sub finish
{
    my ($self) = @_;
    $self->{_database} = 0;
}

sub DESTROY
{
    $_[0]->finish();
}

sub getDatabase
{
    my ($self) = @_;
    return $self->{_database} || die("no database in " . ref($self));
}


sub loadUsers # (%args) return LISTREF
# args:
# one of: 	email | userid | username | partialname => LIST or SCALAR.
#
# addrs			=> 0 | 1
# groups     	=> 0 | 1
# everything 	=> 0 | 1
{
	my ($self, %args) = @_;

	### Identify the KEY FIELD (id,email,username) and KEY VALUE ####
	my $keyfield = requireAny(\%args, 
		[ qw(email userid username partialname) ] 
	);

	# now get the value in {email}, {userid}, etc.
	my $keyvalues = $args{$keyfield} || $self->abort(
		"loadUsers: key field " . $keyfield . " missing");

	# make it into a list if it isn't one...
	if (! ref($keyvalues))
	{
		$keyvalues = [ $keyvalues ];
	} 

	### Formulate the Query using keyfield name/value ################
	# Queries/load-by-email = select * ...
	my $sql = $self->getConfig("load-by-" . $keyfield, section => 'Queries')
        || sprintf("SELECT * FROM %s WHERE %s in (/LIST/)",
			$self->_getUserTableName(), $self->_getRealFieldName($keyfield)
            );

	### Do the query ##############################
	my $db = $self->getDatabase();
	my $res = $db->query(sql => $sql, 
        sqlargs => $keyvalues, 
        substitute => 1,
    );

	if ($#$res < 0)
	{
		$self->setError("No users found with $keyfield=" . 
            join("/", @$keyvalues)) unless ($args{quietfail});
		return ($res);
	}

	# Virtual Field Names - copy each real field into its alias (within loop below)
	my $vmap = $self->_getVirtualFieldMap();

    my $objclass = $self->getUserObjectClass();
	my @users;
	my %initargs = $args{args_init} ? %{ $args{args_init} } : ();

	for (my $i=0; $i<=$#$res; $i++)
	{
		my $user = dynamicNew($objclass);

		$user->init( %initargs, creator => $self );	# this will init group/addr listrefs.
		$user->loadFrom($res->[$i]);

		push (@users, $user);

		# copy real fieldnames into virtual fieldnames.	
		foreach my $outfield ( keys %$vmap )
		{
			my $val='';
			my @subfields = split(/\s+/, $vmap->{$outfield});
			foreach my $sf (@subfields)
			{
				$val .= ' ' if ($val);
				$val .= $user->{ $sf };
			}
			
			$user->{$outfield} = $val;
		} 
	}

	# add group idents.
	if ($args{everything} || $args{groups})
	{
		$self->loadGroupsForUsers(\@users);
	} 

	# add group idents.
	if ($args{everything} || $args{addrs})
	{
		$self->loadAddressesForUsers(\@users);
	} 

    foreach my $u (@users)
    {
        $u->analyse();
    } 

	return \@users;
}

sub loadAddressesForUsers # ($userlist)
# Load addresses for a group of users.  This might involve a query into a separate
# address table, or copying fields from the top level of the user object into
# the addresses array.
{
	my ($self, $userlist) = @_;

	# if 'disable-addresses=true' is present, bail out.
	return 0 if ( $self->getConfig('disable-addresses', 
						defaultvalue => 0, bool => 1 ) 
				);

	# Identify the USERID field (might be id, email, whatever...)
	# This is how we find the rows for a particular user in the usergroups table.
	my $useridfield =  $self->getConfig("Groups/user-id-field-for-groups",
            defaultvalue => $self->{_defaultkey} );

	my $userhash = Baldrick::Util::listToHash($userlist, $useridfield,
		unique => 1);

	my @userids = keys (%$userhash);

	my %fieldmap;
	my $query = $self->_formulateUserAddressQuery(\%fieldmap);
	if ($query)
	{
	    my $db = $self->getDatabase();
		my @alladdrs;
		$db->query(sql => $query, results => \@alladdrs, 
			sqlargs => [ @userids ] , substitute => 1
        );

		foreach my $arec (@alladdrs)
		{
			my $uid = $arec->{ $fieldmap{userid} };
			my $user = $userhash->{$uid};
			if ($user)
			{
				$user->_addToAddressList($arec);
			} else {
				$self->setError("extraneous record (id=$uid) reading addrs for users @userids");
			}
		} 
	}

	# pseudoaddresses: if pseudo-address-fields is set, copy those fieldnames
	# form the main part of the user object into a new AddressList entry.
	$self->_importPseudoAddresses($userlist);
	return 0;
}

sub loadGroupsForUsers # ($userlist)
# Load group information for all users in list into $user->{groupList} array
{
	my ($self, $userlist) = @_;

	# if 'disable-groups=true' is present, bail out.
	return 0 if ( $self->getConfig('disable-groups', 
						defaultvalue => 0, bool => 1 ) 
				);

	# Identify the USERID field (might be id, email, whatever...)
	# This is how we find the rows for a particular user in the usergroups table.
	my $useridfield =  $self->getConfig("Groups/user-id-field-for-groups",
            defaultvalue => $self->{_defaultkey});

	my $userhash = Baldrick::Util::listToHash($userlist, $useridfield,
		unique => 1);

	my @userids = keys (%$userhash);

	my %fieldmap;
	my $query = $self->_formulateUserGroupsQuery(\%fieldmap, idlist => \@userids); 

	# print "<hr><h4>QUERY IS: </h4>$query<hr>\n";

    my $db = $self->getDatabase();
	my @allgroups;
	$db->query(sql => $query, results => \@allgroups, 	
		sqlargs => [ @userids ], substitute => 1 );

	# now, for each row, add it to the appropriate user.

	foreach my $grec (@allgroups)
	{
		# identify the user.
		my $uid = $grec->{ $fieldmap{userid} };
		my $user = $userhash->{$uid};
		if ($user)
		{
			foreach my $foo qw(groupid groupname)
			{
				my $realfn = $fieldmap{$foo};
				next if ($realfn eq $foo);

				$grec->{$foo} = $grec->{$realfn} || $grec->{$foo};
			} 

			# print "<li>group: $grec->{groupname} $grec->{description}\n";
			$user->_addToGroups($grec);
		} else {
			$self->setError("extraneous record (id=$uid) reading groups for users @userids");
		}
		# print "<li>$grec->{userid} $grec->{groupname}, uid=$uid</li>\n";
	} 

	return 0;
}

sub _formulateUserAddressQuery # (\%fieldmap);
# return a SQL query to get addresses for a list of users.
{
	my ($self, $fieldmap) = @_;

	my $pfx = $self->getConfig('tableprefix', defaultvalue => '');

	# user-address-table = useraddrs
	my $uatable = $self->getConfig("Addresses/user-address-table",
		defaultvalue => 'useraddrs' );

	if ($uatable eq 'none')
	{
		return 0;
	}

	# user-address-field-userid : field of useraddress record to match with 
	# userid to determine if this address belongs to a particular user.
	$fieldmap->{userid} = $self->getConfig(
		"Addresses/user-address-field-userid", defaultvalue => 'userid');

	# user-address-field-addrid: unique key of an address rec.
	$fieldmap->{addrid} = $self->getConfig(
		"Addresses/user-address-field-addrid", defaultvalue => '');

	my $query = $self->getConfig("Addresses/get-user-address-query");
	return $query if ($query);

	$query = sprintf("SELECT * FROM %s ua WHERE ua.%s in (/LIST/)",
				($pfx . $uatable), 
				$fieldmap->{userid}
		);	
	$query .= sprintf(" ORDER BY ua.%s", $fieldmap->{addrid}) if ($fieldmap->{addrid});

	return $query;
}

sub _formulateUserGroupsQuery # (\%fieldmap)
# return a SQL query to get groups for a list of users.
{
	my ($self, $fieldmap) = @_;

	# first, get the table names; these determine what we'll look for
	# in setting up the fieldmap (though they may not be used if 
	# get-user-groups-query short-circuits the query builder).
	my $pfx = $self->getConfig('tableprefix', defaultvalue => '');
	my $ugtable = $self->getConfig("Groups/user-group-table",
		defaultvalue => 'usergroups' );
	my $gtable = $self->getConfig("Groups/group-table");	# DEFAULT NULL!

	# First, populate the field map with USERGROUPS fields.
	$fieldmap->{userid} = $self->getConfig(
		"Groups/user-group-field-userid", defaultvalue => 'userid');
	$fieldmap->{UG_GID} = $self->getConfig(
		"Groups/user-group-field-groupid", defaultvalue => 'groupid');

	# ...and continue in GROUPS table only if it is defined.
	if ($gtable)
	{
		$fieldmap->{G_GID} = $self->getConfig(
			"Groups/group-field-groupid", defaultvalue => 'groupid'),
		$fieldmap->{groupname} = $self->getConfig(
			"Groups/group-field-groupname", defaultvalue => 'groupname'),
		$fieldmap->{groupid} = $fieldmap->{G_GID};
	} else {
		$fieldmap->{groupname} = $self->getConfig(
			"Groups/user-group-field-groupname", defaultvalue => 'groupname'),
		$fieldmap->{groupid} = $fieldmap->{UG_GID};
	}

	# Look for an explicit query - if it exists, this saves us
	# much work. (Do this only *AFTER* populating fieldmap!)
	my $query = $self->getConfig("Groups/get-user-groups-query");
	return $query if ($query);

	# if 'group-table' is defined, then we're using the TWO-TABLE METHOD.
	if ($gtable)
	{
		# TWO-TABLE METHOD.
		$query = sprintf("SELECT * FROM %s ug INNER JOIN %s g 
				ON (ug.%s = g.%s) WHERE ug.%s in (/LIST/) ORDER BY g.%s",
			($pfx . $ugtable), ($pfx . $gtable), 
			$fieldmap->{UG_GID}, $fieldmap->{G_GID}, 
			$fieldmap->{userid}, $fieldmap->{groupname}, 
		);
	} else {
		# ONE-TABLE METHOD.
		$query = sprintf("SELECT * FROM %s ug 
				WHERE ug.%s in (/LIST/) ORDER BY %s",
				($pfx . $ugtable), 
				$fieldmap->{userid}, $fieldmap->{groupname} 
		);	
	} 
	return $query;
}


sub _getUserTableName
{
	my ($self) = @_;
	return ($self->getConfig('tableprefix') . 
			$self->getConfig('user-table', defaultvalue => 'users')
	);
}

sub _getVirtualFieldMap
{
	my ($self) = @_;

	return $self->getConfig('VirtualFields');
	# return \%rv;
}

sub _getRealFieldName # ( $virtualfield )
# virtual fields are things like email, username, id; these may be represented
# in the database structure as something else.  Return the actual field name
# for our virtual name (which, by default, is the same thing).
{
	my ($self, $fn) = @_;
	return $self->getConfig($fn, section => 'VirtualFields', 
			defaultvalue => $fn);
}

sub changePasswordForUser
# arg user = userObject REQUIRED
# arg password = new password REQUIRED
{
    my ($self, %args) = @_;
    my $user = requireArg(\%args, 'user');
    my $pass = requireArg(\%args, 'password');

    my $pwfield= $self->getConfig("password-field", section => 'Login', 
        required => 1);   # NO DEFAULT.
    my $savepass = $self->preparePasswordForStorage($pass);

	# password-change-sql = update users set password=? where SOME-ID-FIELD = ?
	# password-change-id = (id field...) # FIX ME: make arbitrary parm list...
    my $sql = $self->getConfig("password-change-sql", section => 'Login',
        required => 1);   # NO DEFAULT.
    my $idfield = $self->getConfig("password-change-id", section => 'Login', 
        required => 1);   # NO DEFAULT.

	if ($sql)
	{
		my $db = $self->getDatabase();
		$db->query(sql => $sql, nofetch => 1,
			sqlargs => [ $savepass, $user->{$idfield} ] 
		);
		return 0;
	} 
	return -1;
}

1;
